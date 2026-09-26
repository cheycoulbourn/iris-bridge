import Foundation

// MARK: - Transport

/// One JSON-RPC message per line, UTF-8, newline-delimited — what Claude Code's stdio transport speaks.
public protocol MCPTransport {
    /// The next message, or `nil` at end of input.
    func readMessage() throws -> Data?
    func writeMessage(_ data: Data) throws
}

/// The stdio transport. Reading is line-oriented rather than chunk-oriented because a client is free to hand
/// over two messages in one write, and a transport that answered "a read" with "a message" would drop the
/// second one. Stdout carries nothing but JSON-RPC: anything else on it corrupts the stream, so every log
/// line in this subcommand goes to stderr.
public final class StdioMCPTransport: MCPTransport {
    private let input: FileHandle
    private let output: FileHandle
    private var buffer: [UInt8] = []
    private var reachedEnd = false

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input; self.output = output
    }

    public func readMessage() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Self.trimmed(Array(buffer[..<newline]))
                buffer.removeFirst(newline + 1)
                // A blank line is framing, not a message: answering -32700 to one would push an error at a
                // client that asked nothing.
                if line.isEmpty { continue }
                return Data(line)
            }
            if reachedEnd {
                let line = Self.trimmed(buffer)
                buffer.removeAll()
                return line.isEmpty ? nil : Data(line)
            }
            // `availableData` returns as soon as the pipe has anything and an empty Data at end of input.
            // `read(upToCount:)` waits for the full count or EOF, and Claude Code never closes stdin — so the
            // reply to `initialize` sat behind a read that could not finish, and every connection timed out.
            let chunk = input.availableData
            if chunk.isEmpty { reachedEnd = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    public func writeMessage(_ data: Data) throws {
        var line = data
        line.append(0x0A)
        try output.write(contentsOf: line)
    }

    /// Trailing carriage return and surrounding spaces; a client that writes CRLF is not writing a bad message.
    private static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var slice = bytes[...]
        while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0D { slice = slice.dropFirst() }
        while let last = slice.last, last == 0x20 || last == 0x09 || last == 0x0D { slice = slice.dropLast() }
        return Array(slice)
    }
}


// MARK: - Server

/// The MCP server behind `iris-bridge mcp`: JSON-RPC 2.0 over stdio, the Iris toolset (spec §5.1), and
/// nothing of its own to decide. Every tool call goes to the running helper over loopback, so a terminal
/// agent and a chat session see the same workspace, queue and rules. Started with `--thread <id>` by a chat
/// session, it also lists the permission-prompt tool `approval`.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    /// Newest first. Both revisions use the same stdio framing, so a client pinned to the older one is
    /// answered in the version it asked for rather than told to speak a newer one.
    public static let protocolVersions = ["2025-06-18", "2024-11-05"]

    /// Called by `iris-bridge mcp` before the first byte is read. The client owns stdout, and a client that
    /// closes it before the last reply is written would otherwise kill this process with SIGPIPE in the middle
    /// of a sentence. Ignored, that write fails like any other and the read loop ends at EOF instead.
    public static func ignoreBrokenPipe() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// A terminal agent's calls less than this far apart belong to one burst of work, which the app treats as
    /// one turn when it applies the batch rule (spec §5.1). A chat session's calls carry the real turn instead.
    static let burstGap: TimeInterval = 120

    private let client: ToolCalling
    private let version: String
    private let threadId: String?
    private let now: () -> Date
    private let lock = NSLock()
    private var agent = "agent"
    private var burst = ""
    private var lastCall = Date.distantPast

    public init(client: ToolCalling, version: String, threadId: String? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client; self.version = version; self.threadId = threadId; self.now = now
    }

    /// One message in, at most one message out. Notifications get `nil`: JSON-RPC forbids answering them,
    /// and a reply on stdout to a message with no id is a protocol error the client cannot even match up.
    public func handle(_ requestJSON: Data) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: requestJSON)) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(),
                                "error": ["code": -32700, "message": "Could not read that JSON-RPC message."]])
        }
        let method = message["method"] as? String ?? ""
        guard let id = message["id"], !(id is NSNull) else {
            if method == "initialize" { rememberClient(message["params"] as? [String: Any]) }
            return nil
        }
        guard !method.isEmpty else {
            return Self.encode(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32600, "message": "That request has no method."]])
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            rememberClient(params)
            return reply(id, ["protocolVersion": Self.negotiated(params["protocolVersion"]),
                              "capabilities": ["tools": [String: Any]()],
                              "serverInfo": ["name": "iris-bridge", "version": version]])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.object(IrisToolCatalog.list(includingApproval: threadId != nil))])
        case "tools/call":
            return reply(id, call(name: params["name"] as? String ?? "", arguments: params["arguments"]))
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32601, "message": "iris-bridge does not handle \(method)."]])
        }
    }

    /// Reads until end of input. A tool call can wait on the owner for minutes (an approval), so each one is
    /// answered on its own thread and the others keep flowing; replies are written one at a time. Returns once
    /// the client has closed the pipe and every call in flight has been answered.
    public func run(transport: MCPTransport) throws {
        let inFlight = DispatchGroup()
        let writing = NSLock()
        func write(_ data: Data?) {
            guard let data else { return }
            writing.lock(); defer { writing.unlock() }
            try? transport.writeMessage(data)
        }
        while let message = try transport.readMessage() {
            let isCall = ((try? JSONSerialization.jsonObject(with: message)) as? [String: Any])?["method"] as? String == "tools/call"
            if isCall {
                inFlight.enter()
                DispatchQueue.global().async { write(self.handle(message)); inFlight.leave() }
            } else {
                write(handle(message))
            }
        }
        inFlight.wait()
    }

    /// The version to answer `initialize` with: the client's own when it is one this server speaks, and this
    /// server's newest otherwise — which is how MCP says a server tells a client "not that one, this one".
    static func negotiated(_ requested: Any?) -> String {
        guard let asked = requested as? String, protocolVersions.contains(asked) else { return protocolVersion }
        return asked
    }

    /// The agent a change is attributed to: "claude" or "codex" for their CLIs, otherwise the client's name.
    private func rememberClient(_ params: [String: Any]?) {
        let name = ((params?["clientInfo"] as? [String: Any])?["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = name.lowercased()
        let agent = lowered.contains("claude") ? "claude" : lowered.contains("codex") ? "codex" : String(name.prefix(80))
        guard !agent.isEmpty else { return }
        lock.lock(); self.agent = agent; lock.unlock()
    }

    private func call(name: String, arguments: Any?) -> [String: Any] {
        let arguments = (arguments as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONValue.decode($0) } ?? [:]
        lock.lock()
        let agent = self.agent
        if now().timeIntervalSince(lastCall) > Self.burstGap { burst = "agent-" + UUID().uuidString.lowercased().prefix(8) }
        lastCall = now()
        let turnId = burst
        lock.unlock()
        do {
            return Self.object(try client.call(name: name, arguments: arguments, threadId: threadId, turnId: turnId, agent: agent)) as? [String: Any]
                ?? Self.failure("Iris Bridge sent back something that is not a tool result.")
        } catch let unreachable as AdminClientError {
            return Self.failure(unreachable.agentMessage)
        } catch {
            let sentence = error.localizedDescription
            return Self.failure(sentence.isEmpty ? "Iris Bridge could not do that." : sentence)
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> Data? {
        Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func object(_ value: JSONValue) -> Any {
        (try? JSONSerialization.jsonObject(with: value.encoded(), options: [.fragmentsAllowed])) ?? NSNull()
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not write that reply."}}"#.utf8)
    }
}
