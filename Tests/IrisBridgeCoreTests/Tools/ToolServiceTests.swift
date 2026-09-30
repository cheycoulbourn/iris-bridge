import XCTest
@testable import IrisBridgeCore

private final class Turns: TurnContextProvider {
    var context: TurnContext?
    var references: [(thread: String, turn: String, post: String, profile: String)] = []
    func turnContext(threadId: String) -> TurnContext? { context?.threadId == threadId ? context : nil }
    func referencePost(threadId: String, turnId: String, postID: String, profileID: String) {
        references.append((threadId, turnId, postID, profileID))
    }
}

final class ToolServiceTests: XCTestCase {
    private let thread = "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77"
    private var snapshots: SnapshotStore!
    private var outbox: FakeOutbox!
    private var turns: Turns!
    private var service: ToolService!
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        snapshots = SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: ContextStore(file: folder.appendingPathComponent("context.json")))
        outbox = FakeOutbox()
        turns = Turns()
        let relay = ActionRelay(file: folder.appendingPathComponent("actions.json"), log: nil, answerWait: 2)
        relay.outbox = outbox
        outbox.onSendToOne = { message in
            relay.resolve(actionId: message["actionId"]!.stringValue!, result: ["status": "queued_for_review", "itemID": "item_9"])
        }
        let approvals = ApprovalBroker(turns: turns, log: nil)
        approvals.outbox = outbox
        service = ToolService(reads: IrisReadTools(snapshots: snapshots, hasPairedDevices: { true }), relay: relay,
                              approvals: approvals, snapshots: snapshots, turns: turns)
    }

    private func push() { XCTAssertNil(snapshots.push(profileId: SnapshotFixture.profile, revision: "rev-1", snapshot: SnapshotFixture.json)) }

    func testReadsAnswerFromTheSnapshot() {
        push()
        let result = service.call(name: "iris_list_pillars", arguments: [:], threadId: nil, turnId: nil, agent: "claude")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Slow mornings"))
    }

    func testASuccessfulPostReadReferencesItsKnownPostForBothChatProviders() {
        push()
        let post = "C0000000-0000-4000-8000-000000000001"
        for provider in [Provider.claude, .codex] {
            turns.context = TurnContext(threadId: thread, turnId: provider.rawValue, provider: provider, mentions: [], commandConnectors: [], connectors: ConnectorTable())
            let result = service.call(name: "iris_get_post", arguments: ["postID": .string(post.lowercased())], threadId: thread, turnId: nil, agent: provider.rawValue)
            XCTAssertFalse(result.isError)
            XCTAssertEqual(turns.references.last?.thread, thread)
            XCTAssertEqual(turns.references.last?.turn, provider.rawValue)
            XCTAssertEqual(turns.references.last?.post, post)
            XCTAssertEqual(turns.references.last?.profile, SnapshotFixture.profile)
            XCTAssertNil(result.json["postReference"], "internal metadata must not leak into the MCP envelope")
        }
        XCTAssertEqual(turns.references.count, 2)
    }

    func testFailedMissingTerminalAndOtherReadsEmitNoPostReferences() {
        turns.context = TurnContext(threadId: thread, turnId: "t1", provider: .codex, mentions: [], commandConnectors: [], connectors: ConnectorTable())
        let post: JSONValue = "C0000000-0000-4000-8000-000000000001"
        XCTAssertTrue(service.call(name: "iris_get_post", arguments: ["postID": post], threadId: thread, turnId: nil, agent: "codex").isError)
        push()
        for arguments: [String: JSONValue] in [[:], ["postID": "missing"], ["postID": post, "profileID": .string(UUID().uuidString)]] {
            XCTAssertTrue(service.call(name: "iris_get_post", arguments: arguments, threadId: thread, turnId: nil, agent: "codex").isError)
        }
        _ = service.call(name: "iris_list_posts", arguments: [:], threadId: thread, turnId: nil, agent: "codex")
        _ = service.call(name: "iris_get_post", arguments: ["postID": post], threadId: nil, turnId: "terminal", agent: "codex")
        turns.context = nil
        _ = service.call(name: "iris_get_post", arguments: ["postID": post], threadId: thread, turnId: nil, agent: "codex")
        XCTAssertTrue(turns.references.isEmpty)
    }

    func testASnapshotWithANonUUIDPostCanReadButCannotCreateAClickableReference() {
        var snapshot = SnapshotFixture.json
        var fields = snapshot.objectValue!
        fields["posts"] = [["id": "legacy-post", "title": "Legacy item"]]
        snapshot = .object(fields)
        XCTAssertNil(snapshots.push(profileId: SnapshotFixture.profile, revision: "rev-2", snapshot: snapshot))
        turns.context = TurnContext(threadId: thread, turnId: "t1", provider: .claude, mentions: [], commandConnectors: [], connectors: ConnectorTable())
        XCTAssertFalse(service.call(name: "iris_get_post", arguments: ["postID": "legacy-post"], threadId: thread, turnId: nil, agent: "claude").isError)
        XCTAssertTrue(turns.references.isEmpty)
    }

    func testAChatTurnsChangeCarriesTheThreadTurnAndProvider() {
        turns.context = TurnContext(threadId: thread, turnId: "t4", provider: .codex, mentions: [], commandConnectors: [], connectors: ConnectorTable())
        let result = service.call(name: "iris_create_idea", arguments: ["title": "Kiln cam"], threadId: thread, turnId: nil, agent: "codex-mcp-client")
        XCTAssertTrue(result.text.contains("item_9"), result.text)
        let origin = outbox.sentToOne.first?["action"]?["origin"]
        XCTAssertEqual(origin, ["source": "chat", "agent": "codex", "threadID": .string(thread), "turnID": "t4"])
        XCTAssertEqual(outbox.sentToOne.first?["threadId"]?.stringValue, thread)
    }

    func testATerminalAgentsChangeWaitsOnTheMacWhenNoAppIsConnected() {
        outbox.connected = false
        let result = service.call(name: "iris_create_task", arguments: ["title": "Film"], threadId: nil, turnId: "agent-1a2b3c4d", agent: "claude")
        XCTAssertTrue(result.text.contains("queued_until_iris_connects"), result.text)
        XCTAssertFalse(result.isError)
        let queued = ActionRelay(file: folder.appendingPathComponent("actions.json"), log: nil).pendingForNewDevice()
        XCTAssertEqual(queued.first?["action"]?["origin"], ["source": "agent", "agent": "claude", "turnID": "agent-1a2b3c4d"])
    }

    func testAChatDraftAndItsDateReachInboxTogetherWithConversationLinkage() {
        turns.context = TurnContext(threadId: thread, turnId: "t5", provider: .codex, mentions: [], commandConnectors: [], connectors: ConnectorTable())
        let result = service.call(name: "iris_create_post_draft", arguments: ["title": "Kiln cam", "script": "Creator's exact draft", "date": "2026-10-02"],
                                  threadId: thread, turnId: nil, agent: "codex-mcp-client")
        XCTAssertFalse(result.isError)
        let answer = try? JSONValue.decode(Data(result.text.utf8))
        XCTAssertEqual(answer?["status"], "queued_for_review")
        XCTAssertEqual(answer?["itemID"], "item_9")
        XCTAssertTrue(result.text.contains("Inbox"))
        let request = outbox.sentToOne.first
        XCTAssertEqual(request?["threadId"], .string(thread))
        XCTAssertEqual(request?["action"]?["origin"], ["source": "chat", "agent": "codex", "threadID": .string(thread), "turnID": "t5"])
        let actions = request?["action"]?["actions"]?.arrayValue
        XCTAssertEqual(actions?.map { $0["name"] }, ["iris_create_post_draft", "iris_schedule_post"])
        XCTAssertEqual(actions?.first?["input"]?["script"], "Creator's exact draft")
    }

    func testARevisionMustNameAnItemTheCreatorAskedToChange() {
        push()
        XCTAssertEqual(service.call(name: "iris_revise_review_item", arguments: ["itemID": "item_0001", "tool": "iris_create_task", "input": ["title": "x"]],
                                    threadId: nil, turnId: nil, agent: "claude"),
                       .failure("The creator has not asked for changes to that item, so it cannot be revised."))
        XCTAssertEqual(service.call(name: "iris_revise_review_item", arguments: ["itemID": "item_nope", "tool": "iris_create_task", "input": ["title": "x"]],
                                    threadId: nil, turnId: nil, agent: "claude"),
                       .failure("That Inbox item was not found. Read iris_list_review_items for its id."))
        let revised = service.call(name: "iris_revise_review_item",
                                   arguments: ["itemID": "item_0002", "tool": "iris_create_series",
                                               "input": ["name": "Morning light", "episodes": [["number": 1, "post": ["title": "One"]]]]],
                                   threadId: nil, turnId: nil, agent: "claude")
        XCTAssertFalse(revised.isError, revised.text)
        XCTAssertEqual(outbox.sentToOne.last?["action"]?["origin"]?["revisionOf"], "item_0002")
        XCTAssertEqual(outbox.sentToOne.last?["action"]?["actions"]?.arrayValue?.first?["name"], "iris_create_series")
    }

    func testTheApprovalToolIsOnlyForChatSessions() {
        XCTAssertEqual(service.call(name: "approval", arguments: ["tool_name": "mcp__iris__iris_list_posts", "input": [:]], threadId: nil, turnId: nil, agent: "claude"),
                       .failure("approval is only for chat sessions Iris Bridge starts."))
        turns.context = TurnContext(threadId: thread, turnId: "t1", provider: .claude, mentions: [], commandConnectors: [], connectors: ConnectorTable())
        let answer = service.call(name: "approval", arguments: ["tool_name": "mcp__iris__iris_list_posts", "input": ["limit": 5], "tool_use_id": "toolu_1"],
                                  threadId: thread, turnId: nil, agent: "claude")
        XCTAssertEqual(try JSONValue.decode(Data(answer.text.utf8)), ["behavior": "allow", "updatedInput": ["limit": 5]])
    }

    func testAnUnknownToolIsAToolError() {
        XCTAssertEqual(service.call(name: "iris_submit_post", arguments: [:], threadId: nil, turnId: nil, agent: "claude"), .failure("iris-bridge has no tool called iris_submit_post."))
    }
}
