import XCTest
@testable import IrisBridgeCore

final class StreamProtocolTests: XCTestCase {
    private func decode(_ json: String) throws -> AppMessage { try AppMessage.decode(Data(json.utf8)) }
    private let thread = "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77"

    func testEveryAppMessageDecodes() throws {
        XCTAssertEqual(try decode(#"{"type":"hello","deviceToken":"t","appVersion":"1.0 (139)","protocol":3,"cursors":{"\#(thread)":41}}"#),
                       .hello(.init(deviceToken: "t", appVersion: "1.0 (139)", protocol: 3, cursors: [thread: 41])))
        XCTAssertEqual(try decode(#"{"type":"thread.open","threadId":"\#(thread)","provider":"claude","model":"haiku"}"#),
                       .threadOpen(.init(threadId: thread, provider: .claude, model: "haiku")))
        guard case .threadSend(let send) = try decode(#"{"type":"thread.send","threadId":"\#(thread)","turnId":"t1","provider":"claude","text":"Plan my week","command":{"kind":"iris","name":"plan-week","connectors":["claude_ai_Google_Calendar"]},"mentions":["claude_ai_Gmail"],"attachments":[{"kind":"document","name":"brief.md","text":"Brief"}],"catchUp":[{"role":"user","text":"From the train"}]}"#) else {
            return XCTFail("not a thread.send")
        }
        XCTAssertEqual(send.command?.connectors, ["claude_ai_Google_Calendar"])
        XCTAssertEqual(send.mentions, ["claude_ai_Gmail"])
        XCTAssertEqual(send.attachments?.first?.text, "Brief")
        XCTAssertEqual(send.catchUp?.first?.text, "From the train")
        XCTAssertEqual(try decode(#"{"type":"turn.cancel","threadId":"\#(thread)","turnId":"t1"}"#), .turnCancel(.init(threadId: thread, turnId: "t1")))
        XCTAssertEqual(try decode(#"{"type":"approval.answer","approvalId":"ap_1","decision":"allow","edited":{"summary":"Lunch"}}"#),
                       .approvalAnswer(.init(approvalId: "ap_1", decision: "allow", edited: ["summary": "Lunch"])))
        XCTAssertEqual(try decode(#"{"type":"action.result","actionId":"act_1","result":{"status":"ok"}}"#),
                       .actionResult(.init(actionId: "act_1", result: ["status": "ok"])))
        XCTAssertEqual(try decode(#"{"type":"snapshot.push","profileId":"p","revision":"r","snapshot":{"schemaVersion":2}}"#),
                       .snapshotPush(.init(profileId: "p", revision: "r", snapshot: ["schemaVersion": 2])))
    }

    func testANewerAppsMessageTypeIsIgnoredNotRefused() throws {
        XCTAssertEqual(try decode(#"{"type":"thread.rename","threadId":"x"}"#), .unknown("thread.rename"))
        XCTAssertThrowsError(try decode(#"{"threadId":"x"}"#))
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"{"type":"hello","protocol":3}"#), "a hello without a token is unreadable")
    }

    private func send(text: String = "Hi", provider: Provider = .claude, model: String? = nil, command: AppMessage.Command? = nil,
                      mentions: [String]? = nil, attachments: [AppMessage.Attachment]? = nil) -> AppMessage.ThreadSend {
        AppMessage.ThreadSend(threadId: thread, turnId: "t1", provider: provider, model: model, text: text, command: command,
                              mentions: mentions, attachments: attachments, catchUp: nil)
    }

    func testThreadSendProblemsAreSentencesAndAGoodOneHasNone() {
        XCTAssertNil(send().problem())
        var bad = send(); bad.threadId = "../etc"
        XCTAssertEqual(bad.problem(), "This message has no valid thread or turn id.")
        XCTAssertEqual(send(text: "  ").problem(), "Enter a message.")
        XCTAssertNil(send(text: "", command: .init(kind: "claude", name: "superpowers:brainstorming", connectors: nil)).problem())
        XCTAssertEqual(send(text: String(repeating: "a", count: 24_001)).problem(), "Enter a message under 24,000 characters.")
        XCTAssertEqual(send(model: "--dangerously").problem(), "Choose a valid model identifier.")
        XCTAssertEqual(send(provider: .codex, command: .init(kind: "claude", name: "x", connectors: nil)).problem(), "Claude commands only work with Claude.")
        XCTAssertEqual(send(provider: .codex, mentions: ["claude_ai_Gmail"]).problem(), "Connectors only work with Claude.")
        XCTAssertEqual(send(attachments: [.init(kind: "image", name: nil, mime: "image/gif", data: "AAAA", text: nil)]).problem(), "Use JPEG or PNG images.")
        XCTAssertEqual(send(attachments: [.init(kind: "video", name: nil, mime: nil, data: nil, text: nil)]).problem(), "Attach images or documents only.")
    }

    func testTurnEventsRenderTheWireShape() {
        let failure = ProviderFailure(cause: .usageLimit, provider: "claude", details: "You've hit your session limit",
                                      resetsAt: Date(timeIntervalSince1970: 1_790_205_600))
        let failed = TurnEvent.failed(failure).message(threadId: thread, turnId: "t1")
        XCTAssertEqual(failed["type"], "turn.failed")
        XCTAssertEqual(failed["cause"], "usageLimit")
        XCTAssertEqual(failed["details"], "You've hit your session limit")
        XCTAssertEqual(failed["resetsAt"], "2026-09-23T23:20:00Z")
        XCTAssertEqual(failed["turnId"], "t1")
        XCTAssertEqual(TurnEvent.textDelta("Hel").message(threadId: thread, turnId: "t1")["text"], "Hel")
        let tool = TurnEvent.toolFinished(toolUseId: "toolu_1", name: "iris_list_posts", ok: true, summary: "Read 3 posts").message(threadId: thread, turnId: "t1")
        XCTAssertEqual(tool["type"], "tool.finished")
        XCTAssertEqual(tool["ok"], true)
        XCTAssertTrue(TurnEvent.completed(TurnUsage()).isTerminal)
        XCTAssertFalse(TurnEvent.thinking.isTerminal)
    }
}
