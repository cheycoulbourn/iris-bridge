import Foundation

/// Carries change requests to the app, the only writer of Iris data (spec §4), and brings its answers back.
/// A request goes to one connected device and waits up to `answerWait` for `action.result`; with no device
/// connected, or no answer in time, it stays queued on this Mac (`actions.json`) and is sent again on every
/// `hello` until an app answers or a week has passed.
public final class ActionRelay: @unchecked Sendable {
    public static let keep: TimeInterval = 7 * 24 * 60 * 60

    public enum Outcome: Equatable { case answered(JSONValue), queued }

    private struct Entry { var actionId: String; var message: JSONValue; var createdAt: Date; var sentAt: Date? }

    private let file: URL
    private let log: BridgeLog?
    private let now: () -> Date
    private let answerWait: TimeInterval
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var waiters: [String: DispatchSemaphore] = [:]
    private var answers: [String: JSONValue] = [:]
    public weak var outbox: StreamOutbox?

    public init(file: URL, log: BridgeLog?, answerWait: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.file = file; self.log = log; self.answerWait = answerWait; self.now = now
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONValue.decode($0) }?.arrayValue ?? []
        entries = saved.compactMap { item in
            guard let id = item["actionId"]?.stringValue, let message = item["request"],
                  let created = item["createdAt"]?.stringValue.flatMap(IrisSnapshot.timestamp) else { return nil }
            return Entry(actionId: id, message: message, createdAt: created, sentAt: nil)
        }
    }

    /// A new id for one tool call.
    public static func newActionId() -> String { "act_" + UUID().uuidString.lowercased() }

    /// Sends one request and waits for its answer. Blocks the calling thread for up to `answerWait`.
    public func request(actionId: String, actions: [JSONValue], origin: JSONValue, threadId: String?) -> Outcome {
        var message: [String: JSONValue] = ["type": "action.request", "actionId": .string(actionId),
                                            "action": ["actions": .array(actions), "origin": origin]]
        if let threadId { message["threadId"] = .string(threadId) }
        let waiter = DispatchSemaphore(value: 0)
        lock.lock()
        entries.append(Entry(actionId: actionId, message: .object(message), createdAt: now(), sentAt: nil))
        waiters[actionId] = waiter
        saveLocked()
        lock.unlock()
        let sent = outbox?.sendToOne(.object(message)) ?? false
        if sent {
            markSent(actionId)
            _ = waiter.wait(timeout: .now() + answerWait)
        }
        lock.lock(); defer { lock.unlock() }
        waiters[actionId] = nil
        // An answer that landed just after the wait timed out is still this call's answer.
        guard let answer = answers.removeValue(forKey: actionId) else {
            log?.info("action \(actionId) waits on this Mac until Iris connects")
            return .queued
        }
        return .answered(answer)
    }

    /// `action.result`. An answer for a request nobody is waiting on any more (it was queued) just clears it.
    public func resolve(actionId: String, result: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        guard entries.contains(where: { $0.actionId == actionId }) else { return }
        entries.removeAll { $0.actionId == actionId }
        saveLocked()
        if let waiter = waiters[actionId] { answers[actionId] = result; waiter.signal() }
        log?.info("action \(actionId) answered: \(result["status"]?.stringValue ?? "?")")
    }

    /// What a device that just said hello should be sent: every queued request not already sent to a device
    /// within the last `answerWait` (that device may still answer it). Marks them sent.
    public func pendingForNewDevice() -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-Self.keep)
        let before = entries.count
        entries.removeAll { $0.createdAt < cutoff }
        if entries.count != before { saveLocked() }
        var out: [JSONValue] = []
        for index in entries.indices where entries[index].sentAt.map({ now().timeIntervalSince($0) >= answerWait }) ?? true {
            entries[index].sentAt = now()
            out.append(entries[index].message)
        }
        return out
    }

    private func markSent(_ actionId: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.actionId == actionId }) { entries[index].sentAt = now() }
    }

    private func saveLocked() {
        let formatter = ISO8601DateFormatter()
        let saved = JSONValue.array(entries.map { ["actionId": .string($0.actionId), "request": $0.message,
                                                   "createdAt": .string(formatter.string(from: $0.createdAt))] })
        do { try BridgePaths.writePrivate(saved.encoded(), to: file) }
        catch { log?.error("could not save queued actions") }
    }
}
