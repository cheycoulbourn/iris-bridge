import XCTest
@testable import IrisBridgeCore

final class IrisChangeToolsTests: XCTestCase {
    func testOneCallIsOneRequestInThePhase2Envelope() throws {
        let task = try IrisChangeTools.actions(tool: "iris_create_task", arguments: ["title": "Film the intro", "profileID": "a1b2c3d4-0000-4000-8000-000000000001"], actionId: "act_1")
        XCTAssertEqual(task, [["id": "act_1.0", "name": "iris_create_task", "profileID": "A1B2C3D4-0000-4000-8000-000000000001", "input": ["title": "Film the intro"]]])
        let dated = try IrisChangeTools.actions(tool: "iris_create_post_draft", arguments: ["title": "Glazing day", "date": "2026-10-09", "time": "18:00"], actionId: "act_2")
        XCTAssertEqual(dated.map { $0["name"] }, ["iris_create_post_draft", "iris_schedule_post"])
        XCTAssertNil(dated[0]["input"]?["date"])
        XCTAssertEqual(dated[1]["input"], ["date": "2026-10-09", "time": "18:00"])
        XCTAssertNil(dated[1]["profileID"], "no profile means the one open in Iris")
        let archive = try IrisChangeTools.actions(tool: "iris_archive", arguments: ["records": [["kind": "post", "id": "p1", "expectedRevision": "r"], ["kind": "idea", "id": "i1"]]], actionId: "act_3")
        XCTAssertEqual(archive.map { $0["id"] }, ["act_3.0", "act_3.1"])
        XCTAssertEqual(archive[1]["input"], ["kind": "idea", "id": "i1"])
    }

    func testMissingRequiredInputAndBadCallsAreRefusedBeforeAnythingIsSent() {
        func refusal(_ tool: String, _ arguments: [String: JSONValue]) -> String? {
            do { _ = try IrisChangeTools.actions(tool: tool, arguments: arguments, actionId: "a"); return nil }
            catch { return error.localizedDescription }
        }
        XCTAssertEqual(refusal("iris_update_task", ["title": "x"]), "iris_update_task needs taskID.")
        XCTAssertEqual(refusal("iris_list_posts", [:]), "iris_list_posts is not an Iris change tool.")
        XCTAssertEqual(refusal("iris_create_task", ["title": "x", "profileID": "me"]), "profileID must be a profile id from iris_workspace_summary.")
        XCTAssertEqual(refusal("iris_archive", ["records": []]), "iris_archive needs 1 to 100 records.")
        XCTAssertEqual(refusal("iris_archive", ["records": [["kind": "calendar", "id": "x"]]]), "Each record to archive needs its kind (post, task, idea or series) and id.")
    }

    func testResultsReadTheWayTheModelNeeds() {
        XCTAssertEqual(IrisChangeTools.result(["status": "ok", "recordIDs": ["r1"], "activityID": "act:x"]).isError, false)
        XCTAssertTrue(IrisChangeTools.result(["status": "queued_for_review", "itemID": "item_1"]).text.contains("item_1"))
        XCTAssertEqual(IrisChangeTools.result(["status": "refused", "message": "That task is not in this workspace."]), .failure("That task is not in this workspace."))
        let queued = IrisChangeTools.queued(actionId: "act_9").text
        XCTAssertTrue(queued.contains("queued_until_iris_connects"))
        // Every Iris build before the new chat is open without receiving changes, so the note must not say Iris is closed.
        XCTAssertFalse(queued.contains("not open on a paired device."), queued)
        XCTAssertTrue(queued.contains("Older Iris builds do not receive agent changes"), queued)
        XCTAssertTrue(queued.contains("up to a week"), queued)
        XCTAssertEqual(IrisChangeTools.origin(agent: "claude", threadId: "T", turnId: "t1"), ["source": "chat", "agent": "claude", "threadID": "T", "turnID": "t1"])
        XCTAssertEqual(IrisChangeTools.origin(agent: "codex", threadId: nil, turnId: nil), ["source": "agent", "agent": "codex"])
    }
}

final class ActionRelayTests: XCTestCase {
    private var file: URL!
    private var outbox: FakeOutbox!
    private let action: JSONValue = ["id": "act_1.0", "name": "iris_create_task", "input": ["title": "x"]]

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        outbox = FakeOutbox()
    }

    private func relay(wait: TimeInterval = 2, now: @escaping () -> Date = Date.init) -> ActionRelay {
        let relay = ActionRelay(file: file, log: nil, answerWait: wait, now: now)
        relay.outbox = outbox
        return relay
    }

    func testAConnectedAppsAnswerComesBack() {
        let relay = relay()
        outbox.onSendToOne = { message in
            relay.resolve(actionId: message["actionId"]!.stringValue!, result: ["status": "ok", "recordIDs": ["r1"]])
        }
        let outcome = relay.request(actionId: "act_1", actions: [action], origin: ["source": "agent"], threadId: nil)
        XCTAssertEqual(outcome, .answered(["status": "ok", "recordIDs": ["r1"]]))
        XCTAssertEqual(outbox.sentToOne.first?["type"], "action.request")
        XCTAssertEqual(outbox.sentToOne.first?["action"]?["actions"], [action])
        XCTAssertEqual(relay.pendingForNewDevice(), [], "an answered request is not sent again")
    }

    func testWithNoAppItQueuesAndTheNextHelloGetsIt() {
        outbox.connected = false
        let first = relay()
        XCTAssertEqual(first.request(actionId: "act_1", actions: [action], origin: ["source": "agent"], threadId: nil), .queued)
        let restarted = relay()
        let pending = restarted.pendingForNewDevice()
        XCTAssertEqual(pending.map { $0["actionId"] }, ["act_1"])
        XCTAssertEqual(restarted.pendingForNewDevice(), [], "a request just sent is not sent to a second device at once")
        restarted.resolve(actionId: "act_1", result: ["status": "queued_for_review", "itemID": "item_1"])
        XCTAssertEqual(relay().pendingForNewDevice(), [])
    }

    func testNoAnswerInTimeQueuesAndALateAnswerStillClearsIt() {
        let relay = relay(wait: 0.2)
        XCTAssertEqual(relay.request(actionId: "act_1", actions: [action], origin: ["source": "agent"], threadId: "T"), .queued)
        XCTAssertEqual(outbox.sentToOne.first?["threadId"], "T")
        relay.resolve(actionId: "act_1", result: ["status": "ok"])
        XCTAssertEqual(relay.pendingForNewDevice(), [])
    }

    func testAWeekOldRequestIsDropped() {
        outbox.connected = false
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let relay = relay(now: { clock })
        _ = relay.request(actionId: "act_1", actions: [action], origin: ["source": "agent"], threadId: nil)
        clock = clock.addingTimeInterval(ActionRelay.keep + 1)
        XCTAssertEqual(relay.pendingForNewDevice(), [])
    }
}
