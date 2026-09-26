import Foundation

/// The v3 stream (spec §6.2): JSON text messages over `wss://<host>:48731/v3/stream`. This file is the whole
/// wire vocabulary in both directions; the plan's Shared contract is the prose version of it.
public enum StreamProtocol {
    public static let version = 3
    public static let path = "/v3/stream"
}

// MARK: - App → helper

/// One message from the app. A type this helper does not know is `.unknown`, which the hub logs and
/// ignores, so a newer app never breaks an older helper.
public enum AppMessage: Equatable {
    case hello(Hello)
    case threadOpen(ThreadOpen)
    case threadSend(ThreadSend)
    case turnCancel(TurnCancel)
    case approvalAnswer(ApprovalAnswer)
    case actionResult(ActionResult)
    case snapshotPush(SnapshotPush)
    case unknown(String)

    public struct Hello: Decodable, Equatable {
        public var deviceToken: String
        public var appVersion: String?
        public var `protocol`: Int
        /// The last `seq` the app holds for each thread it wants replayed.
        public var cursors: [String: Int]?
    }

    /// The app opened a thread's screen: the helper starts its provider process now, so the first reply
    /// is not held up by a cold start (spec §6.3). Not in spec §6.2's list; added because §6.3 needs it.
    public struct ThreadOpen: Decodable, Equatable {
        public var threadId: String
        public var provider: Provider
        public var model: String?
    }

    public struct ThreadSend: Decodable, Equatable {
        public var threadId: String
        public var turnId: String
        public var provider: Provider
        public var model: String?
        /// Nil is Automatic (the provider's own default); a given value must be one of the `effort` capability's
        /// fixed vocabulary (`StreamIdentifiers.efforts`). Omitted on a later send, the session's current
        /// effort is kept; given and different, the session restarts with `--resume` once the running turn ends.
        public var effort: String?
        public var text: String
        public var command: Command?
        public var mentions: [String]?
        public var attachments: [Attachment]?
        public var catchUp: [CatchUp]?
    }

    /// A `/` command. `iris` commands arrive already expanded into `text` and name the connectors they may
    /// read; `claude` commands are the owner's own skills and commands, sent to Claude as `/name text`.
    public struct Command: Decodable, Equatable {
        public var kind: String
        public var name: String
        public var connectors: [String]?
    }

    /// An image (`data` is base64 JPEG or PNG) or a document the app already turned into text.
    public struct Attachment: Decodable, Equatable {
        public var kind: String
        public var name: String?
        public var mime: String?
        public var data: String?
        public var text: String?
    }

    /// A message written while away (spec §7), prepended to the next turn as a short summary (§6.3).
    public struct CatchUp: Decodable, Equatable {
        public var role: String
        public var text: String
    }

    public struct TurnCancel: Decodable, Equatable {
        public var threadId: String
        public var turnId: String
    }

    public struct ApprovalAnswer: Decodable, Equatable {
        public var approvalId: String
        public var decision: String
        /// Replacement tool input; reaches Claude as the permission answer's `updatedInput`.
        public var edited: JSONValue?
    }

    public struct ActionResult: Decodable, Equatable {
        public var actionId: String
        public var result: JSONValue
    }

    public struct SnapshotPush: Decodable, Equatable {
        public var profileId: String
        public var revision: String
        public var snapshot: JSONValue
    }

    private struct Envelope: Decodable { var type: String }

    /// Reads one text frame. Throws when it is not JSON, has no `type`, or a known type lacks a field it needs.
    public static func decode(_ data: Data) throws -> AppMessage {
        let decoder = JSONDecoder()
        let type = try decoder.decode(Envelope.self, from: data).type
        switch type {
        case "hello": return .hello(try decoder.decode(Hello.self, from: data))
        case "thread.open": return .threadOpen(try decoder.decode(ThreadOpen.self, from: data))
        case "thread.send": return .threadSend(try decoder.decode(ThreadSend.self, from: data))
        case "turn.cancel": return .turnCancel(try decoder.decode(TurnCancel.self, from: data))
        case "approval.answer": return .approvalAnswer(try decoder.decode(ApprovalAnswer.self, from: data))
        case "action.result": return .actionResult(try decoder.decode(ActionResult.self, from: data))
        case "snapshot.push": return .snapshotPush(try decoder.decode(SnapshotPush.self, from: data))
        default: return .unknown(type)
        }
    }
}

public enum StreamLimits {
    /// The largest message either side sends: a 16 MiB snapshot, or four 5 MB images as base64 with text.
    public static let maximumMessageBytes = 32 * 1024 * 1024
    public static let maximumText = 24_000
    public static let maximumImages = 4
    public static let maximumImageBytes = 5_000_000
    public static let maximumDocuments = 8
    public static let maximumDocumentText = 200_000
    public static let maximumCatchUp = 50
    public static let maximumMentions = 20
}

/// Thread ids are the app's UUIDs; the helper names files after them, so nothing else is accepted.
public enum StreamIdentifiers {
    public static func isThreadID(_ text: String) -> Bool { UUID(uuidString: text) != nil }

    /// Turn, action and approval ids: 1–100 of `A-Z a-z 0-9 . _ : -`.
    public static func isToken(_ text: String) -> Bool {
        guard (1...100).contains(text.count) else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".-_:".unicodeScalars.contains($0) }
    }

    /// The v2 model rule: no spaces or controls, no leading dash, at most 120 characters.
    public static func isModel(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 120 && !text.hasPrefix("-")
            && text.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// The `effort` capability's fixed vocabulary, low to high. A `thread.send.effort` outside this list is
    /// refused; Codex maps xhigh and max onto its own highest documented level (`CodexCommandLine.codexEffort`).
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
}

extension AppMessage.ThreadSend {
    /// The sentence to send back when this message cannot be run, or nil when it can. Checked before any
    /// provider is started, so a bad message costs nothing.
    public func problem() -> String? {
        guard StreamIdentifiers.isThreadID(threadId), StreamIdentifiers.isToken(turnId) else { return "This message has no valid thread or turn id." }
        if let model, !StreamIdentifiers.isModel(model) { return "Choose a valid model identifier." }
        if let effort, !StreamIdentifiers.efforts.contains(effort) { return "Choose a valid reasoning effort." }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && command == nil { return "Enter a message." }
        if text.count > StreamLimits.maximumText { return "Enter a message under 24,000 characters." }
        if let command {
            guard ["iris", "claude"].contains(command.kind), !command.name.isEmpty, command.name.count <= 120,
                  !command.name.contains(where: { $0.isWhitespace }) else { return "That command is not one Iris knows." }
            if command.kind == "claude", provider != .claude { return "Claude commands only work with Claude." }
        }
        let mentions = mentions ?? []
        if mentions.count > StreamLimits.maximumMentions || mentions.contains(where: { $0.isEmpty || $0.count > 120 }) {
            return "Mention up to 20 connectors."
        }
        if provider == .codex && !mentions.isEmpty { return "Connectors only work with Claude." }
        let attachments = attachments ?? []
        let images = attachments.filter { $0.kind == "image" }
        let documents = attachments.filter { $0.kind == "document" }
        guard images.count + documents.count == attachments.count else { return "Attach images or documents only." }
        if images.count > StreamLimits.maximumImages { return "Choose up to four images." }
        for image in images {
            guard ["image/jpeg", "image/png"].contains(image.mime ?? "") else { return "Use JPEG or PNG images." }
            guard let bytes = Data(base64Encoded: image.data ?? "") else { return "Could not read an attached image." }
            guard bytes.count <= StreamLimits.maximumImageBytes else { return "Use images smaller than 5 MB." }
        }
        if documents.count > StreamLimits.maximumDocuments { return "Attach up to eight documents." }
        if documents.reduce(0, { $0 + ($1.text?.count ?? 0) }) > StreamLimits.maximumDocumentText {
            return "The attached documents are too long. Attach less text."
        }
        let catchUp = catchUp ?? []
        if catchUp.count > StreamLimits.maximumCatchUp || catchUp.reduce(0, { $0 + $1.text.count }) > StreamLimits.maximumText {
            return "Too much happened while you were away to catch up in one message."
        }
        return nil
    }
}

// MARK: - Helper → app

/// What happened in one turn, in the order it happened. Each becomes one logged, replayable message.
public enum TurnEvent: Equatable {
    case started(provider: Provider, model: String, sessionId: String)
    /// Claude is thinking before it writes (spec §6.2); sent once per thinking block.
    case thinking
    case textDelta(String)
    case toolStarted(toolUseId: String, name: String, summary: String)
    case toolFinished(toolUseId: String, name: String, ok: Bool, summary: String)
    case completed(TurnUsage)
    case failed(ProviderFailure)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }

    /// The message as sent, before the event log stamps `seq`.
    public func message(threadId: String, turnId: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["threadId": .string(threadId), "turnId": .string(turnId)]
        switch self {
        case .started(let provider, let model, let sessionId):
            body["type"] = "turn.started"; body["provider"] = .string(provider.rawValue); body["model"] = .string(model)
            // Codex names its session only once the first run starts; the app fills §8's providerSessions from it.
            if !sessionId.isEmpty { body["sessionId"] = .string(sessionId) }
        case .thinking:
            body["type"] = "thinking"
        case .textDelta(let text):
            body["type"] = "text.delta"; body["text"] = .string(text)
        case .toolStarted(let id, let name, let summary):
            body["type"] = "tool.started"; body["toolUseId"] = .string(id); body["name"] = .string(name); body["summary"] = .string(summary)
        case .toolFinished(let id, let name, let ok, let summary):
            body["type"] = "tool.finished"; body["toolUseId"] = .string(id); body["name"] = .string(name)
            body["ok"] = .bool(ok); body["summary"] = .string(summary)
        case .completed(let usage):
            body["type"] = "turn.completed"; body["usage"] = usage.json
        case .failed(let failure):
            body["type"] = "turn.failed"
            body["cause"] = .string(failure.cause.rawValue)
            body["message"] = .string(failure.sentence())
            if let details = failure.details { body["details"] = .string(details) }
            if let resetsAt = failure.resetsAt { body["resetsAt"] = .string(ISO8601DateFormatter().string(from: resetsAt)) }
        }
        return body
    }
}

public struct TurnUsage: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
    }
    public var json: JSONValue {
        ["inputTokens": .number(Double(inputTokens)), "outputTokens": .number(Double(outputTokens)),
         "cacheReadTokens": .number(Double(cacheReadTokens)), "cacheCreationTokens": .number(Double(cacheCreationTokens))]
    }
}

/// Messages that are not part of a thread's log.
public enum HelperMessage {
    public static func helloOK(helperVersion: String, capabilities: [String], health: JSONValue) -> JSONValue {
        ["type": "hello.ok", "helperVersion": .string(helperVersion),
         "capabilities": .array(capabilities.map { .string($0) }), "health": health]
    }

    public static func healthChanged(_ health: JSONValue) -> JSONValue {
        ["type": "health.changed", "health": health]
    }
}
