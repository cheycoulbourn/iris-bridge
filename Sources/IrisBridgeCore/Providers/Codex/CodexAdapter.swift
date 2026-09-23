import Foundation

/// Where a Codex run happens and how its Iris tools reach this helper.
public struct CodexSetup {
    public var binary: () -> String?
    public var helperBinary: String
    public var root: URL
    public var port: UInt16
    public var workingDirectory: URL

    public init(binary: @escaping () -> String?, helperBinary: String, root: URL, port: UInt16, workingDirectory: URL) {
        self.binary = binary; self.helperBinary = helperBinary; self.root = root; self.port = port; self.workingDirectory = workingDirectory
    }
}

/// Codex (limited, spec §6.4): one `codex exec --json` run per turn, resumed by its thread id. No connectors and
/// no Claude commands; Iris tools only. Replies arrive whole, not as deltas.
public final class CodexAdapter: ProviderAdapter {
    public let provider = Provider.codex
    private let setup: CodexSetup
    private let launcher: ProcessLauncher
    private let healthCheck: () -> ProviderHealth

    public init(setup: CodexSetup, launcher: ProcessLauncher, health: @escaping () -> ProviderHealth) {
        self.setup = setup; self.launcher = launcher; self.healthCheck = health
    }

    public func session(threadId: String, resume sessionId: String?, model: String?,
                        events: @escaping (ProviderEvent) -> Void) throws -> ProviderSession {
        guard setup.binary() != nil else {
            throw ProviderFailure(cause: .providerUnavailable, provider: "codex", message: "Install Codex on your Mac first.")
        }
        return CodexSession(threadId: threadId, sessionId: sessionId, model: model, setup: setup, launcher: launcher, events: events)
    }

    public func health() -> ProviderHealth { healthCheck() }
}

final class CodexSession: ProviderSession, @unchecked Sendable {
    private let threadId: String
    let model: String?
    private let setup: CodexSetup
    private let launcher: ProcessLauncher
    private let events: (ProviderEvent) -> Void
    private let queue = DispatchQueue(label: "iris-bridge.codex-session")
    private var id: String?
    private var process: ProviderProcess?
    private var turnId: String?
    private var lines: [String] = []
    private var cancelled = false
    private var imageFolder: URL?

    init(threadId: String, sessionId: String?, model: String?, setup: CodexSetup, launcher: ProcessLauncher, events: @escaping (ProviderEvent) -> Void) {
        self.threadId = threadId; self.id = sessionId; self.model = model; self.setup = setup; self.launcher = launcher; self.events = events
    }

    var sessionId: String? { queue.sync { id } }
    var isLive: Bool { false }

    func send(_ turn: TurnRequest) throws {
        guard let binary = setup.binary() else {
            throw ProviderFailure(cause: .providerUnavailable, provider: "codex", message: "Install Codex on your Mac first.")
        }
        try FileManager.default.createDirectory(at: setup.workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [String] = []
        var folder: URL?
        if !turn.images.isEmpty {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("iris-bridge-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (index, image) in turn.images.enumerated() {
                let file = made.appendingPathComponent("image-\(index).\(image.mime == "image/png" ? "png" : "jpg")")
                try Data(base64Encoded: image.base64)?.write(to: file)
                files.append(file.path)
            }
            folder = made
        }
        try queue.sync {
            let resuming = id
            let prompt = resuming == nil ? IrisPrompt.system + "\n\n" + turn.text : turn.text
            let command = ProviderCommand(arguments: CodexCommandLine.arguments(binary: binary, resume: resuming, model: model, helperBinary: setup.helperBinary,
                                                                                threadId: threadId, root: setup.root, port: setup.port, images: files),
                                          workingDirectory: setup.workingDirectory, input: Data(prompt.utf8))
            turnId = turn.turnId; lines = []; cancelled = false; imageFolder = folder
            process = try launcher.launch(command, line: { [weak self] line in self?.queue.async { self?.handle(line) } },
                                          exit: { [weak self] status, stderr in self?.queue.async { self?.exited(status, stderr) } })
        }
    }

    /// Codex exec has no interrupt; stopping the run is the only way, and it loses the partial reply.
    func cancel() {
        queue.async {
            guard self.turnId != nil else { return }
            self.cancelled = true
            self.process?.terminate()
        }
    }

    func stop() { cancel() }

    private func handle(_ line: Data) {
        guard let current = turnId else { return }
        lines.append(String(decoding: line, as: UTF8.self))
        for item in CodexStream.items(line) {
            switch item {
            case .threadStarted(let thread):
                if id != thread { id = thread; events(.session(id: thread)) }
            case .reasoning:
                events(.turn(turnId: current, .thinking))
            case .toolStarted(let itemId, let server, let tool):
                events(.turn(turnId: current, .toolStarted(toolUseId: itemId, name: tool, summary: Self.activity(server: server, tool: tool))))
            case .toolFinished(let itemId, _, let tool, let ok, let text):
                events(.turn(turnId: current, .toolFinished(toolUseId: itemId, name: tool, ok: ok, summary: ok ? "Done" : OneLineText.clean(text, limit: 200))))
            case .message(let text):
                events(.turn(turnId: current, .textDelta(text)))
            case .completed(let usage):
                finish(.completed(usage))
            case .failed:
                finish(.failed(ProviderOutput.codexFailure(ProcessResult(status: 1, stdout: lines.joined(separator: "\n"), stderr: ""))))
            }
        }
    }

    private func exited(_ status: Int32, _ stderr: String) {
        if turnId != nil {
            finish(.failed(cancelled ? ProviderFailure(cause: .cancelled, provider: "codex")
                           : ProviderOutput.codexFailure(ProcessResult(status: status, stdout: lines.joined(separator: "\n"), stderr: stderr))))
        }
        if let imageFolder { try? FileManager.default.removeItem(at: imageFolder) }
        imageFolder = nil
        process = nil
    }

    private func finish(_ event: TurnEvent) {
        guard let current = turnId else { return }
        turnId = nil
        events(.turn(turnId: current, event))
    }

    static func activity(server: String, tool: String) -> String {
        if server == "iris", let iris = IrisToolCatalog.tool(named: tool) { return iris.activity }
        return "\(server): \(ToolClassifier.words(tool).joined(separator: " "))"
    }
}
