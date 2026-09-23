import Foundation

/// The helper's side of the v3 stream: what each app message does, and what a device that just said hello
/// is sent (spec §6.2): `hello.ok`, the events it missed in each thread it names, then every question and
/// change still waiting for an answer.
public final class BridgeStreams: StreamHandler {
    private let sessions: SessionManager
    private let approvals: ApprovalBroker
    private let relay: ActionRelay
    private let snapshots: SnapshotStore
    private let health: HealthMonitor
    private let log: BridgeLog?

    public init(sessions: SessionManager, approvals: ApprovalBroker, relay: ActionRelay, snapshots: SnapshotStore, health: HealthMonitor, log: BridgeLog?) {
        self.sessions = sessions; self.approvals = approvals; self.relay = relay; self.snapshots = snapshots; self.health = health; self.log = log
    }

    public func helloOK(for device: PairedDevice) -> JSONValue {
        HelperMessage.helloOK(helperVersion: BridgeVersion.current, capabilities: BridgeVersion.capabilities, health: health.report())
    }

    public func connected(device: PairedDevice, cursors: [String: Int], send: @escaping (JSONValue) -> Void) {
        for (threadId, cursor) in cursors.sorted(by: { $0.key < $1.key }) {
            for event in sessions.replay(threadId: threadId, after: cursor) { send(event) }
        }
        for question in approvals.waiting() { send(question) }
        for request in relay.pendingForNewDevice() { send(request) }
        health.refresh()
    }

    public func received(_ message: AppMessage, from device: PairedDevice) {
        switch message {
        case .threadOpen(let open): sessions.open(open)
        case .threadSend(let send): sessions.send(send)
        case .turnCancel(let cancel): sessions.cancel(cancel)
        case .approvalAnswer(let answer):
            guard ["allow", "deny"].contains(answer.decision) else { log?.info("an approval answer with an unknown decision was ignored"); return }
            approvals.answer(approvalId: answer.approvalId, decision: answer.decision, edited: answer.edited)
        case .actionResult(let result): relay.resolve(actionId: result.actionId, result: result.result)
        case .snapshotPush(let push):
            if let problem = snapshots.push(profileId: push.profileId, revision: push.revision, snapshot: push.snapshot) {
                log?.info("snapshot from device \(device.id) refused: \(problem)")
            }
        case .hello, .unknown:
            break
        }
    }

    public func disconnected(device: PairedDevice) {}
}
