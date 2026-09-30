import Foundation

/// The turn a thread is answering right now, if any. `SessionManager` is the real one.
public protocol TurnContextProvider: AnyObject {
    func turnContext(threadId: String) -> TurnContext?
    /// A successful read of a known snapshot post; the real manager rechecks that this turn is active.
    func referencePost(threadId: String, turnId: String, postID: String, profileID: String)
}

public extension TurnContextProvider {
    func referencePost(threadId: String, turnId: String, postID: String, profileID: String) {}
}

/// Runs the permission-prompt tool (`mcp__iris__approval`, spec §6.5). Claude calls it with `{tool_name,
/// input, tool_use_id}` before every tool use it has not been pre-allowed; the answer is the permission result
/// Claude expects: `{"behavior":"allow","updatedInput":{…}}` or `{"behavior":"deny","message":"…"}`. A
/// connector write is sent to every connected app as `approval.request` and waits up to ten minutes (verified:
/// a prompt can wait 610 s); no answer is a deny.
public final class ApprovalBroker: @unchecked Sendable {
    public static let wait: TimeInterval = 600

    private struct Pending { var message: JSONValue; var threadId: String; var turnId: String; var input: JSONValue; var waiter: DispatchSemaphore; var answer: JSONValue? }

    private let turns: TurnContextProvider
    private let log: BridgeLog?
    private let wait: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    public weak var outbox: StreamOutbox?

    public init(turns: TurnContextProvider, log: BridgeLog?, wait: TimeInterval = ApprovalBroker.wait, now: @escaping () -> Date = Date.init) {
        self.turns = turns; self.log = log; self.wait = wait; self.now = now
    }

    public func check(threadId: String, toolName: String, input: JSONValue) -> JSONValue {
        let turn = turns.turnContext(threadId: threadId)
        switch ApprovalPolicy.decide(toolName: toolName, input: input, turn: turn) {
        case .allow:
            return ["behavior": "allow", "updatedInput": input]
        case .deny(let reason):
            log?.info("approval: denied \(toolName) in thread \(threadId)")
            return ["behavior": "deny", "message": .string(reason)]
        case .ask(let kind, let summary, let detail):
            guard let turn else { return ["behavior": "deny", "message": "This chat has no message being answered."] }
            return ask(turn: turn, kind: kind, summary: summary, detail: detail, input: input)
        }
    }

    private func ask(turn: TurnContext, kind: String, summary: String, detail: JSONValue, input: JSONValue) -> JSONValue {
        let approvalId = "ap_" + UUID().uuidString.lowercased()
        let expiresAt = ISO8601DateFormatter().string(from: now().addingTimeInterval(wait))
        let message: JSONValue = ["type": "approval.request", "approvalId": .string(approvalId), "threadId": .string(turn.threadId),
                                  "turnId": .string(turn.turnId), "kind": .string(kind), "summary": .string(summary),
                                  "detail": detail, "expiresAt": .string(expiresAt)]
        let waiter = DispatchSemaphore(value: 0)
        lock.lock()
        pending[approvalId] = Pending(message: message, threadId: turn.threadId, turnId: turn.turnId, input: input, waiter: waiter)
        lock.unlock()
        outbox?.broadcast(message)
        log?.info("approval \(approvalId) asked in thread \(turn.threadId)")
        let answered = waiter.wait(timeout: .now() + wait) == .success
        lock.lock()
        let answer = pending.removeValue(forKey: approvalId)?.answer
        lock.unlock()
        guard answered, let answer else {
            log?.info("approval \(approvalId) expired")
            return ["behavior": "deny", "message": "The creator did not answer within 10 minutes, so this was not done."]
        }
        return answer
    }

    /// `approval.answer` from any device; the first answer wins.
    public func answer(approvalId: String, decision: String, edited: JSONValue?) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = pending[approvalId], entry.answer == nil else { return }
        entry.answer = decision == "allow"
            ? ["behavior": "allow", "updatedInput": edited ?? entry.input]
            : ["behavior": "deny", "message": "The creator declined this."]
        pending[approvalId] = entry
        entry.waiter.signal()
        log?.info("approval \(approvalId) \(decision == "allow" ? "allowed" : "denied")")
    }

    /// A turn that ends while it waits (cancelled, failed, its process gone) denies what it was waiting on.
    public func endTurn(threadId: String, turnId: String) {
        lock.lock(); defer { lock.unlock() }
        for (id, var entry) in pending where entry.threadId == threadId && entry.turnId == turnId && entry.answer == nil {
            entry.answer = ["behavior": "deny", "message": "The creator stopped this reply."]
            pending[id] = entry
            entry.waiter.signal()
        }
    }

    /// Every question still waiting, for a device that just said hello.
    public func waiting() -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return pending.values.filter { $0.answer == nil }.map(\.message)
    }
}
