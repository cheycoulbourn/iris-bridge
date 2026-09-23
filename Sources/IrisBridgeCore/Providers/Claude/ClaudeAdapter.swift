import Foundation

/// Where a Claude session runs and how its Iris tools reach this helper.
public struct ClaudeSetup {
    public var binary: () -> String?
    /// This helper's own executable, which Claude starts as the `iris` MCP server.
    public var helperBinary: String
    public var root: URL
    public var port: UInt16
    /// The empty folder sessions run in (spec §6.4).
    public var workingDirectory: URL

    public init(binary: @escaping () -> String?, helperBinary: String, root: URL, port: UInt16, workingDirectory: URL) {
        self.binary = binary; self.helperBinary = helperBinary; self.root = root; self.port = port; self.workingDirectory = workingDirectory
    }
}

/// Claude (full, spec §6.4): one long-lived `claude -p` stream-json process per active thread, one user
/// message per turn, `interrupt` to cancel.
public final class ClaudeAdapter: ProviderAdapter {
    public let provider = Provider.claude
    private let setup: ClaudeSetup
    private let launcher: ProcessLauncher
    private let healthCheck: () -> ProviderHealth
    private let timing: ClaudeSession.Timing

    public init(setup: ClaudeSetup, launcher: ProcessLauncher, health: @escaping () -> ProviderHealth, timing: ClaudeSession.Timing = .standard) {
        self.setup = setup; self.launcher = launcher; self.healthCheck = health; self.timing = timing
    }

    public func session(threadId: String, resume sessionId: String?, model: String?,
                        events: @escaping (ProviderEvent) -> Void) throws -> ProviderSession {
        guard let binary = setup.binary() else {
            throw ProviderFailure(cause: .providerUnavailable, provider: "claude", message: "Install Claude Code on your Mac first.")
        }
        try FileManager.default.createDirectory(at: setup.workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = sessionId ?? UUID().uuidString.lowercased()
        let mcp = ClaudeCommandLine.mcpConfig(helperBinary: setup.helperBinary, threadId: threadId, root: setup.root, port: setup.port)
        let command = ProviderCommand(arguments: ClaudeCommandLine.arguments(binary: binary, sessionId: id, resume: sessionId != nil, model: model, mcpConfig: mcp),
                                      workingDirectory: setup.workingDirectory)
        let session = ClaudeSession(sessionId: id, model: model, timing: timing, events: events)
        try session.start(command, launcher: launcher)
        return session
    }

    public func health() -> ProviderHealth { healthCheck() }
}

/// One Claude process and the turn it is answering.
public final class ClaudeSession: ProviderSession, @unchecked Sendable {
    public struct Timing {
        /// When to ask for `mcp_status` after starting: account connectors were connected about 3.5 s in (spike Q1).
        public var statusDelay: TimeInterval
        /// How long an interrupted turn may take to end before its process is stopped (spike q5-d ended in 26 ms).
        public var interruptGrace: TimeInterval
        /// A turn that prints nothing for this long is stopped as timed out. Longer than an approval's 10 minutes.
        public var silenceLimit: TimeInterval
        public static let standard = Timing(statusDelay: 4, interruptGrace: 10, silenceLimit: 20 * 60)
        public init(statusDelay: TimeInterval, interruptGrace: TimeInterval, silenceLimit: TimeInterval) {
            self.statusDelay = statusDelay; self.interruptGrace = interruptGrace; self.silenceLimit = silenceLimit
        }
    }

    private struct Turn { var id: String; var lines: [Data] = []; var tools: [String: String] = [:]; var interrupted = false; var lastHeard = Date() }

    public let sessionId: String?
    public let model: String?
    private let timing: Timing
    private let events: (ProviderEvent) -> Void
    private let queue = DispatchQueue(label: "iris-bridge.claude-session")
    private var process: ProviderProcess?
    private var alive = false
    private var turn: Turn?
    private var commands: JSONValue?
    private var connectors: ConnectorTable?
    private var requests = 0
    private var watchdog: DispatchSourceTimer?

    init(sessionId: String, model: String?, timing: Timing, events: @escaping (ProviderEvent) -> Void) {
        self.sessionId = sessionId; self.model = model; self.timing = timing; self.events = events
    }

    public var isLive: Bool { queue.sync { alive } }

    func start(_ command: ProviderCommand, launcher: ProcessLauncher) throws {
        let process = try launcher.launch(command, line: { [weak self] line in self?.queue.async { self?.handle(line) } },
                                          exit: { [weak self] status, stderr in self?.queue.async { self?.exited(status, stderr) } })
        queue.sync {
            self.process = process
            alive = true
            control("initialize", id: "iris-initialize")
        }
        queue.asyncAfter(deadline: .now() + timing.statusDelay) { [weak self] in self?.askStatus() }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 30, repeating: 30)
        watchdog.setEventHandler { [weak self] in self?.checkSilence() }
        watchdog.resume()
        queue.sync { self.watchdog = watchdog }
    }

    public func send(_ request: TurnRequest) throws {
        try queue.sync {
            guard alive, let process else { throw ProviderFailure(cause: .internal, provider: "claude", message: "Claude Code stopped before the message was sent. Send it again.") }
            turn = Turn(id: request.turnId)
            askStatus()
            let content: JSONValue = request.images.isEmpty ? .string(request.text)
                : .array([["type": "text", "text": .string(request.text)]] + request.images.map {
                    ["type": "image", "source": ["type": "base64", "media_type": .string($0.mime), "data": .string($0.base64)]]
                })
            process.write(JSONValue.object(["type": "user", "message": ["role": "user", "content": content]]).encoded())
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self, var current = turn, !current.interrupted else { return }
            current.interrupted = true
            turn = current
            control("interrupt", id: "iris-interrupt-\(nextRequest())")
            queue.asyncAfter(deadline: .now() + timing.interruptGrace) { [weak self] in
                guard let self, turn?.id == current.id else { return }
                process?.terminate()
            }
        }
    }

    public func stop() {
        queue.async {
            self.process?.closeInput()
            let process = self.process
            self.queue.asyncAfter(deadline: .now() + 5) { process?.terminate() }
        }
    }

    // MARK: - Output

    private func handle(_ line: Data) {
        if turn != nil { turn?.lines.append(line); turn?.lastHeard = Date() }
        for item in ClaudeStream.items(line) {
            switch item {
            case .controlResponse(let id, let ok, let response):
                guard ok else { continue }
                if id == "iris-initialize" { commands = response["commands"] ?? .array([]) }
                if id.hasPrefix("iris-status") { connectors = ConnectorTable(mcpStatus: response) }
                if let commands, let connectors { events(.catalog(commands: commands, connectors: connectors)) }
            case .initialized(_, let apiKeySource):
                // Home mode runs on the subscription only (spec §10); API keys are stripped from the environment,
                // and a session that still chose one is stopped before it spends anything.
                guard let source = apiKeySource, source != "none", let current = turn else { continue }
                finish(current.id, .failed(ProviderFailure(cause: .signedOut, provider: "claude", details: "apiKeySource: \(source)",
                                                           message: "Claude selected API-key billing. Use your Claude account sign-in and try again.")))
                process?.terminate()
            case .thinking:
                if let current = turn { events(.turn(turnId: current.id, .thinking)) }
            case .text(let text):
                if let current = turn { events(.turn(turnId: current.id, .textDelta(text))) }
            case .toolUse(let id, let name):
                guard var current = turn, name != "ToolSearch" else { continue }
                let shown = Self.shownName(name)
                current.tools[id] = shown
                turn = current
                events(.turn(turnId: current.id, .toolStarted(toolUseId: id, name: shown, summary: Self.activity(name, connectors: connectors))))
            case .toolResult(let id, let isError, let text):
                guard let current = turn, let shown = current.tools[id] else { continue }
                events(.turn(turnId: current.id, .toolFinished(toolUseId: id, name: shown, ok: !isError,
                                                               summary: isError ? OneLineText.clean(text, limit: 200) : "Done")))
            case .rateLimit(let limited, let resetsAt):
                events(.usage(limited: limited, resetsAt: resetsAt))
            case .result(let result):
                guard let current = turn else { continue }
                if current.interrupted {
                    finish(current.id, .failed(ProviderFailure(cause: .cancelled, provider: "claude")))
                } else if result["subtype"]?.stringValue == "success", result["is_error"]?.boolValue != true {
                    let usage = result["usage"]
                    finish(current.id, .completed(TurnUsage(inputTokens: usage?["input_tokens"]?.intValue ?? 0,
                                                            outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                                                            cacheReadTokens: usage?["cache_read_input_tokens"]?.intValue ?? 0,
                                                            cacheCreationTokens: usage?["cache_creation_input_tokens"]?.intValue ?? 0)))
                } else {
                    let stdout = current.lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
                    finish(current.id, .failed(ProviderOutput.claudeFailure(ProcessResult(status: 1, stdout: stdout, stderr: ""))))
                }
            }
        }
    }

    private func exited(_ status: Int32, _ stderr: String) {
        alive = false
        watchdog?.cancel(); watchdog = nil
        if let current = turn {
            let stdout = current.lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
            let failure = current.interrupted ? ProviderFailure(cause: .cancelled, provider: "claude")
                : ProviderOutput.claudeFailure(ProcessResult(status: status, stdout: stdout, stderr: stderr))
            finish(current.id, .failed(failure))
        }
        events(.ended)
    }

    private func finish(_ turnId: String, _ event: TurnEvent) {
        guard turn?.id == turnId else { return }
        turn = nil
        events(.turn(turnId: turnId, event))
    }

    private func checkSilence() {
        guard let current = turn, Date().timeIntervalSince(current.lastHeard) > timing.silenceLimit else { return }
        finish(current.id, .failed(ProviderFailure(cause: .timeout, provider: "claude")))
        process?.terminate()
    }

    private func askStatus() {
        guard alive else { return }
        control("mcp_status", id: "iris-status-\(nextRequest())")
    }

    private func control(_ subtype: String, id: String) {
        process?.write(JSONValue.object(["type": "control_request", "request_id": .string(id), "request": ["subtype": .string(subtype)]]).encoded())
    }

    private func nextRequest() -> Int { requests += 1; return requests }

    /// Iris tools are shown by their own name; everything else by its full tool id.
    static func shownName(_ tool: String) -> String {
        tool.hasPrefix("mcp__iris__") ? String(tool.dropFirst("mcp__iris__".count)) : tool
    }

    /// What the chat card says while a tool runs.
    static func activity(_ tool: String, connectors: ConnectorTable?) -> String {
        if let iris = IrisToolCatalog.tool(named: shownName(tool)) { return iris.activity }
        if let (connector, name) = connectors?.connector(forTool: tool) {
            return "\(connector.name): \(ToolClassifier.words(name).joined(separator: " "))"
        }
        return "Using a tool"
    }
}
