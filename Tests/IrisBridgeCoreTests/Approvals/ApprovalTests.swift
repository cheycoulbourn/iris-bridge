import XCTest
@testable import IrisBridgeCore

/// The recorded shape of an `mcp_status` answer (spike q2-f, Claude Code 2.1.274), with fictional servers.
enum MCPStatusFixture {
    static var json: JSONValue {
        let url = Bundle.module.url(forResource: "claude-mcp-status", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.decode(Data(contentsOf: url))
    }
    static var table: ConnectorTable { ConnectorTable(mcpStatus: json) }
}

final class ConnectorTableTests: XCTestCase {
    func testOnlyAccountConnectorsCountAndTheirToolIdsResolve() {
        let table = MCPStatusFixture.table
        XCTAssertEqual(table.connectors.map(\.id), ["claude_ai_Gmail", "claude_ai_Google_Calendar", "claude_ai_Notion"])
        XCTAssertEqual(table.connectors.map(\.name), ["Gmail", "Google Calendar", "Notion"])
        XCTAssertEqual(table.connectors.last?.status, "needs-auth")
        XCTAssertEqual(table.connector(forTool: "mcp__claude_ai_Google_Calendar__list_calendars")?.tool, "list_calendars")
        XCTAssertNil(table.connector(forTool: "mcp__iris__iris_list_posts"))
        XCTAssertNil(table.connector(forTool: "mcp__localtools__run_anything"))
        XCTAssertEqual(ConnectorTable.normalize("claude.ai Google Calendar"), "claude_ai_Google_Calendar")
        XCTAssertEqual(table.json.arrayValue?.first?["tools"]?.intValue, 5)
    }
}

final class ToolClassifierTests: XCTestCase {
    private let table = MCPStatusFixture.table

    func testAnnotationsDecideFirstThenTheNameRule() {
        XCTAssertEqual(ToolClassifier.classify("ToolSearch", connectors: table), .toolSearch)
        XCTAssertEqual(ToolClassifier.classify("mcp__iris__iris_create_task", connectors: table), .iris)
        guard case .connectorRead = ToolClassifier.classify("mcp__claude_ai_Gmail__search_threads", connectors: table) else { return XCTFail("annotated read") }
        guard case .connectorRead = ToolClassifier.classify("mcp__claude_ai_Gmail__get_thread", connectors: table) else { return XCTFail("read by name") }
        guard case .connectorWrite = ToolClassifier.classify("mcp__claude_ai_Gmail__create_draft", connectors: table) else { return XCTFail("write by name") }
        guard case .connectorWrite = ToolClassifier.classify("mcp__claude_ai_Gmail__trash_thread", connectors: table) else { return XCTFail("destructive") }
        guard case .connectorWrite = ToolClassifier.classify("mcp__claude_ai_Gmail__send_message", connectors: table) else { return XCTFail("openWorld is not read-only") }
        guard case .connectorWrite = ToolClassifier.classify("mcp__claude_ai_Gmail__summarize_inbox", connectors: table) else { return XCTFail("unrecognised is a write") }
        // Each annotation against a name that says the opposite.
        XCTAssertFalse(ToolClassifier.isReadByName("suggest_time"))
        guard case .connectorRead = ToolClassifier.classify("mcp__claude_ai_Google_Calendar__suggest_time", connectors: table) else { return XCTFail("readOnly beats a name with no read word") }
        XCTAssertTrue(ToolClassifier.isReadByName("fetch_and_clear_reminders"))
        guard case .connectorWrite = ToolClassifier.classify("mcp__claude_ai_Google_Calendar__fetch_and_clear_reminders", connectors: table) else { return XCTFail("destructive beats a read-like name") }
        XCTAssertEqual(ToolClassifier.classify("mcp__localtools__run_anything", connectors: table), .other)
        XCTAssertEqual(ToolClassifier.classify("mcp__iris__approval", connectors: table), .other, "the model may not call the permission tool itself")
        XCTAssertEqual(ToolClassifier.classify("Bash", connectors: table), .other)
    }

    func testAReadOnlyClaimCountsOnlyWhenTheNameDoesNotLeadWithAWrite() {
        let calendar = table.connectors[1]
        XCTAssertEqual(ToolClassifier.classify("mcp__claude_ai_Google_Calendar__createEventFromTemplate", connectors: table),
                       .connectorWrite(calendar, tool: "createEventFromTemplate"), "a connector's readOnly on a tool that creates is not believed")
        let planner = ConnectorTable(mcpStatus: ["mcpServers": [["name": "claude.ai Planner", "status": "connected", "scope": "claudeai", "tools": [
            ["name": "get_queue_schedule", "annotations": ["readOnly": true]],
            ["name": "list_social_set_posts", "annotations": ["readOnly": true]],
            ["name": "get_or_create_label", "annotations": ["readOnly": true]],
            ["name": "archiveOldPosts", "annotations": ["readOnly": true]],
        ]]]])
        func classify(_ tool: String) -> ToolClass { ToolClassifier.classify("mcp__claude_ai_Planner__" + tool, connectors: planner) }
        let connector = planner.connectors[0]
        XCTAssertEqual(classify("get_queue_schedule"), .connectorRead(connector, tool: "get_queue_schedule"), "a write word after the verb is a noun")
        XCTAssertEqual(classify("list_social_set_posts"), .connectorRead(connector, tool: "list_social_set_posts"))
        XCTAssertEqual(classify("get_or_create_label"), .connectorWrite(connector, tool: "get_or_create_label"), "'or create' is a second verb")
        XCTAssertEqual(classify("archiveOldPosts"), .connectorWrite(connector, tool: "archiveOldPosts"))
        XCTAssertEqual(ToolClassifier.leadingVerbs("createEventFromTemplate"), ["create"])
        XCTAssertEqual(ToolClassifier.leadingVerbs("search_public_and_private"), ["search"])
        XCTAssertEqual(ToolClassifier.leadingVerbs("fetch_and_update_or_delete"), ["fetch", "update", "delete"])
        XCTAssertEqual(ToolClassifier.leadingVerbs("suggest_time"), [])
    }

    func testTheNameRuleReadsWordsNotLetters() {
        XCTAssertTrue(ToolClassifier.isReadByName("notion-fetch"))
        XCTAssertTrue(ToolClassifier.isReadByName("queryDataSources"))
        XCTAssertTrue(ToolClassifier.isReadByName("list_drafts"))
        XCTAssertFalse(ToolClassifier.isReadByName("get_or_create_label"))
        XCTAssertFalse(ToolClassifier.isReadByName("targeted_update"))
        XCTAssertFalse(ToolClassifier.isReadByName("listener_setup"), "'listener' is not 'list'")
        XCTAssertEqual(ToolClassifier.words("respondToEvent-now"), ["respond", "to", "event", "now"])
    }
}

final class ApprovalPolicyTests: XCTestCase {
    private func turn(mentions: Set<String> = [], command: Set<String> = []) -> TurnContext {
        TurnContext(threadId: "T", turnId: "t1", provider: .claude, mentions: mentions, commandConnectors: command, connectors: MCPStatusFixture.table)
    }

    func testIrisToolsRunAndConnectorReadsNeedAMention() {
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__iris__iris_create_task", input: [:], turn: turn()), .allow)
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "ToolSearch", input: [:], turn: turn()), .allow)
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Gmail__search_threads", input: [:], turn: turn()),
                       .deny("Reading Gmail needs the creator to mention it with @Gmail in their message. Ask them to, or answer without it."))
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Gmail__search_threads", input: [:], turn: turn(mentions: ["claude_ai_Gmail"])), .allow)
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Google_Calendar__list_events", input: [:], turn: turn(command: ["claude_ai_Google_Calendar"])), .allow)
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Google_Calendar__list_events", input: [:], turn: turn(mentions: ["claude_ai_Gmail"])),
                       .deny("Reading Google Calendar needs the creator to mention it with @Google Calendar in their message. Ask them to, or answer without it."))
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Google_Calendar__suggest_time", input: [:], turn: turn(mentions: ["claude_ai_Google_Calendar"])), .allow,
                       "annotated read-only, though its name has no read word")
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Google_Calendar__suggest_time", input: [:], turn: turn()),
                       .deny("Reading Google Calendar needs the creator to mention it with @Google Calendar in their message. Ask them to, or answer without it."))
    }

    func testConnectorWritesAskEvenWhenMentionedAndOthersAreRefused() {
        let input: JSONValue = ["to": "sam@example.com", "subject": "Shoot moved"]
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Gmail__send_message", input: input, turn: turn(mentions: ["claude_ai_Gmail"])),
                       .ask(kind: "connectorWrite", summary: "Gmail: send message", detail: ["connector": "Gmail", "tool": "send_message", "input": input]))
        let mentioned = turn(mentions: ["claude_ai_Google_Calendar"])
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Google_Calendar__createEventFromTemplate", input: ["template": "Shoot day"], turn: mentioned),
                       .ask(kind: "connectorWrite", summary: "Google Calendar: create event from template",
                            detail: ["connector": "Google Calendar", "tool": "createEventFromTemplate", "input": ["template": "Shoot day"]]),
                       "marked readOnly by its connector, and still asks")
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__claude_ai_Google_Calendar__fetch_and_clear_reminders", input: [:], turn: mentioned),
                       .ask(kind: "connectorWrite", summary: "Google Calendar: fetch and clear reminders",
                            detail: ["connector": "Google Calendar", "tool": "fetch_and_clear_reminders", "input": [:]]))
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__localtools__run_anything", input: [:], turn: turn()), .deny("That tool is not available in Iris chat."))
        XCTAssertEqual(ApprovalPolicy.decide(toolName: "mcp__iris__iris_create_task", input: [:], turn: nil), .deny("This chat has no message being answered, so no tool can run."))
    }
}

private final class OneTurn: TurnContextProvider {
    var context: TurnContext?
    func turnContext(threadId: String) -> TurnContext? { context?.threadId == threadId ? context : nil }
}

final class ApprovalBrokerTests: XCTestCase {
    private var turns: OneTurn!
    private var outbox: FakeOutbox!

    override func setUp() {
        turns = OneTurn()
        turns.context = TurnContext(threadId: "T", turnId: "t1", provider: .claude, mentions: [], commandConnectors: [], connectors: MCPStatusFixture.table)
        outbox = FakeOutbox()
    }

    private func broker(wait: TimeInterval = 5) -> ApprovalBroker {
        let broker = ApprovalBroker(turns: turns, log: nil, wait: wait)
        broker.outbox = outbox
        return broker
    }

    /// Waits for the broker's question to reach the fake app, then answers it from "the phone".
    private func answerWhenAsked(_ broker: ApprovalBroker, decision: String, edited: JSONValue? = nil) {
        DispatchQueue.global().async {
            while broker.waiting().isEmpty { Thread.sleep(forTimeInterval: 0.01) }
            let id = broker.waiting()[0]["approvalId"]!.stringValue!
            broker.answer(approvalId: id, decision: decision, edited: edited)
        }
    }

    func testAnAllowedToolAnswersAtOnceWithItsOwnInput() {
        XCTAssertEqual(broker().check(threadId: "T", toolName: "mcp__iris__iris_list_posts", input: ["limit": 5]),
                       ["behavior": "allow", "updatedInput": ["limit": 5]])
        XCTAssertEqual(outbox.broadcasts, [])
    }

    func testAWriteAsksEveryDeviceAndTheOwnersEditReachesClaude() {
        let broker = broker()
        answerWhenAsked(broker, decision: "allow", edited: ["summary": "Lunch at 1"])
        let answer = broker.check(threadId: "T", toolName: "mcp__claude_ai_Google_Calendar__create_event", input: ["summary": "Lunch"])
        XCTAssertEqual(answer, ["behavior": "allow", "updatedInput": ["summary": "Lunch at 1"]])
        let asked = outbox.broadcasts.first
        XCTAssertEqual(asked?["type"], "approval.request")
        XCTAssertEqual(asked?["summary"], "Google Calendar: create event")
        XCTAssertEqual(asked?["turnId"], "t1")
        XCTAssertNotNil(asked?["expiresAt"]?.stringValue.flatMap(ISO8601DateFormatter().date(from:)))
        XCTAssertEqual(broker.waiting(), [])
    }

    func testADenyAnUnansweredQuestionAndAStoppedTurnAllDeny() {
        let denying = broker()
        answerWhenAsked(denying, decision: "deny")
        XCTAssertEqual(denying.check(threadId: "T", toolName: "mcp__claude_ai_Gmail__send_message", input: [:]),
                       ["behavior": "deny", "message": "The creator declined this."])
        XCTAssertEqual(broker(wait: 0.2).check(threadId: "T", toolName: "mcp__claude_ai_Gmail__send_message", input: [:]),
                       ["behavior": "deny", "message": "The creator did not answer within 10 minutes, so this was not done."])
        let stopping = broker()
        DispatchQueue.global().async {
            while stopping.waiting().isEmpty { Thread.sleep(forTimeInterval: 0.01) }
            stopping.endTurn(threadId: "T", turnId: "t1")
        }
        XCTAssertEqual(stopping.check(threadId: "T", toolName: "mcp__claude_ai_Gmail__send_message", input: [:]),
                       ["behavior": "deny", "message": "The creator stopped this reply."])
    }
}
