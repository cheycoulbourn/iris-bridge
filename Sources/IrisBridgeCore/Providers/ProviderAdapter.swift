import Foundation

/// One message to a provider: the text the model reads (with any command, catch-up and documents already
/// folded in, `IrisPrompt.turnText`) and the images beside it.
public struct TurnRequest: Equatable {
    public struct Image: Equatable { public var mime: String; public var base64: String }
    public var turnId: String
    public var text: String
    public var images: [Image]
    public init(turnId: String, text: String, images: [Image] = []) { self.turnId = turnId; self.text = text; self.images = images }
}

/// Everything a provider session reports, normalised (spec §6.4): turn events for the thread's log, and what
/// the session learned about itself and the account along the way.
public enum ProviderEvent: Equatable {
    case turn(turnId: String, TurnEvent)
    /// The provider's own session id, when the helper did not choose it (Codex's thread id).
    case session(id: String)
    /// Claude's `/` commands (from `initialize`) and the account connectors (from `mcp_status`).
    case catalog(commands: JSONValue, connectors: ConnectorTable)
    /// Claude's `rate_limit_event`: limited or not, and when the window resets.
    case usage(limited: Bool, resetsAt: Date?)
    /// The session's process went away between turns; the next message starts it again with `--resume`.
    case ended
}

/// A provider session behind one thread.
public protocol ProviderSession: AnyObject {
    /// The id the session resumes by: chosen by the helper for Claude, learned from `thread.started` for Codex.
    var sessionId: String? { get }
    var model: String? { get }
    /// True while a Claude process is alive between turns. Codex runs one process per turn.
    var isLive: Bool { get }
    func send(_ turn: TurnRequest) throws
    /// Stops the turn in progress, keeping what was already written (Claude's `interrupt`).
    func cancel()
    /// Ends the session's process (idle, or the helper stopping). The provider keeps the conversation.
    func stop()
}

/// A ProviderAdapter per CLI (spec §6.4): start or resume a session, send a turn, cancel, health.
public protocol ProviderAdapter: AnyObject {
    var provider: Provider { get }
    /// A session for `threadId`, resuming `sessionId` when there is one. `events` gets everything the
    /// session reports, on a background thread, in order.
    func session(threadId: String, resume sessionId: String?, model: String?,
                 events: @escaping (ProviderEvent) -> Void) throws -> ProviderSession
    func health() -> ProviderHealth
}
