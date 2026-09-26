import XCTest
@testable import IrisBridgeCore

/// The Claude adapter against recorded stream-json transcripts (Fixtures/claude-*.jsonl; shapes from the phase 1
/// spike's runs on Claude Code 2.1.274, content fictional). No test signs in or spends anything.
final class ClaudeAdapterTests: XCTestCase {
    private let thread = "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77"
    private let root = URL(fileURLWithPath: "/tmp/iris-bridge-tests/root")
    /// `mcp_status` goes with each message only, so a transcript's order never depends on a timer.
    private let timing = ClaudeSession.Timing(statusDelay: 3600, interruptGrace: 1, silenceLimit: 3600)

    private func adapter(_ launcher: ScriptedLauncher, binary: String? = "/usr/local/bin/claude") -> ClaudeAdapter {
        ClaudeAdapter(setup: ClaudeSetup(binary: { binary }, helperBinary: "/Applications/Iris Bridge/iris-bridge", root: root, port: 48731,
                                         workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("iris-sessions")),
                      launcher: launcher,
                      health: { ProviderHealth(installed: true, signedIn: true, account: "Max", cliVersion: "2.1.274", usage: .ok) },
                      timing: timing)
    }

    func testTheCommandLineIsTheOneTheSpikeVerified() throws {
        let launcher = ScriptedLauncher("claude-session-turns")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: "haiku", events: { _ in })
        let arguments = try XCTUnwrap(launcher.commands.first?.arguments)
        XCTAssertEqual(Array(arguments.prefix(8)), ["/usr/local/bin/claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                                    "--verbose", "--include-partial-messages"])
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        XCTAssertEqual(value("--tools"), "ToolSearch")
        XCTAssertEqual(value("--permission-mode"), "manual")
        XCTAssertEqual(value("--permission-prompts"), "host")
        XCTAssertEqual(value("--permission-prompt-tool"), "mcp__iris__approval")
        XCTAssertEqual(value("--model"), "haiku")
        XCTAssertNil(value("--effort"), "Automatic sends no flag")
        XCTAssertEqual(value("--session-id"), session.sessionId)
        XCTAssertNil(value("--resume"))
        XCTAssertEqual(value("--append-system-prompt"), IrisPrompt.system)
        let mcp = try JSONValue.decode(Data(try XCTUnwrap(value("--mcp-config")).utf8))
        XCTAssertEqual(mcp["mcpServers"]?["iris"]?["command"], "/Applications/Iris Bridge/iris-bridge")
        XCTAssertEqual(mcp["mcpServers"]?["iris"]?["args"], ["mcp", "--thread", .string(thread), "--root", "/tmp/iris-bridge-tests/root", "--port", "48731"])
        for banned in ["--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] {
            XCTAssertFalse(arguments.contains(banned), banned)
        }
        XCTAssertEqual(launcher.processes.first?.writes.first?["request"]?["subtype"], "initialize", "the command list is asked for at start")
    }

    func testResumingUsesTheSameId() throws {
        let launcher = ScriptedLauncher("claude-session-turns")
        let session = try adapter(launcher).session(threadId: thread, resume: "9d361c48-33a2-45b4-b457-66fe34dc80bf", model: nil, events: { _ in })
        let arguments = launcher.commands[0].arguments
        XCTAssertEqual(arguments.firstIndex(of: "--resume").map { arguments[$0 + 1] }, "9d361c48-33a2-45b4-b457-66fe34dc80bf")
        XCTAssertFalse(arguments.contains("--session-id"))
        XCTAssertFalse(arguments.contains("--model"))
        XCTAssertEqual(session.sessionId, "9d361c48-33a2-45b4-b457-66fe34dc80bf")
    }

    /// The `effort` capability: a given effort resumes with `--resume ... --effort`, and the session reports
    /// what it was started with so `SessionManager.canReuse` can tell a later change apart from a repeat.
    func testAGivenEffortResumesWithItsOwnFlag() throws {
        let launcher = ScriptedLauncher("claude-session-turns")
        let session = try adapter(launcher).session(threadId: thread, resume: "9d361c48-33a2-45b4-b457-66fe34dc80bf", model: nil, effort: "xhigh", events: { _ in })
        let arguments = launcher.commands[0].arguments
        XCTAssertEqual(arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] }, "xhigh")
        XCTAssertEqual(session.effort, "xhigh")
    }

    func testATurnStreamsThinkingThenTextAndCompletesWithUsage() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("claude-session-turns")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Good morning"))
        XCTAssertEqual(recorder.waitForEnd(of: "t1"), .completed(TurnUsage(inputTokens: 10, outputTokens: 42, cacheReadTokens: 6691, cacheCreationTokens: 9356)))
        XCTAssertEqual(recorder.turn("t1"), [.thinking, .textDelta("Good "), .textDelta("morning."),
                                             .completed(TurnUsage(inputTokens: 10, outputTokens: 42, cacheReadTokens: 6691, cacheCreationTokens: 9356))])
        XCTAssertTrue(recorder.all.contains(.usage(limited: false, resetsAt: Date(timeIntervalSince1970: 1_790_150_400))))
        guard case .catalog(let commands, let connectors)? = recorder.all.first(where: { if case .catalog = $0 { return true }; return false }) else {
            return XCTFail("no catalog")
        }
        XCTAssertEqual(commands.arrayValue?.map { $0["name"] }, ["brainstorm", "superpowers:writing-plans"])
        XCTAssertEqual(connectors.connectors.map(\.name), ["Gmail", "Google Calendar", "Notion"])
        XCTAssertTrue(session.isLive)
    }

    func testToolsBecomeCardsExceptToolSearchAndADeniedReadSaysWhy() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("claude-session-turns")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Good morning"))
        _ = recorder.waitForEnd(of: "t1")
        try session.send(TurnRequest(turnId: "t2", text: "What is planned this week?"))
        _ = recorder.waitForEnd(of: "t2")
        XCTAssertEqual(recorder.turn("t2"), [
            .toolStarted(toolUseId: "toolu_02", name: "iris_list_posts", summary: "Reading your posts"),
            .toolFinished(toolUseId: "toolu_02", name: "iris_list_posts", ok: true, summary: "Done"),
            .toolStarted(toolUseId: "toolu_03", name: "mcp__claude_ai_Gmail__search_threads", summary: "Gmail: search threads"),
            .toolFinished(toolUseId: "toolu_03", name: "mcp__claude_ai_Gmail__search_threads", ok: false,
                          summary: "Reading Gmail needs the creator to mention it with @Gmail in their message. Ask them to, or answer without it."),
            .textDelta("Nothing is planned "), .textDelta("this week."),
            .completed(TurnUsage(inputTokens: 12, outputTokens: 30, cacheReadTokens: 16000, cacheCreationTokens: 200))
        ])
    }

    /// Spike q5-d: `interrupt` ends the turn with `error_during_execution`, keeps what was written, and the
    /// same process answers the next message.
    func testCancelInterruptsAndTheSessionAnswersTheNextMessage() throws {
        let recorder = EventRecorder()
        let launcher = ScriptedLauncher("claude-interrupt")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Count from 1 to 300."))
        recorder.wait { $0.contains(.turn(turnId: "t1", .textDelta("1\n"))) }
        session.cancel()
        XCTAssertEqual(recorder.waitForEnd(of: "t1"), .failed(ProviderFailure(cause: .cancelled, provider: "claude")))
        XCTAssertTrue(launcher.processes[0].writes.contains { $0["request"]?["subtype"] == "interrupt" })
        XCTAssertTrue(session.isLive)
        try session.send(TurnRequest(turnId: "t2", text: "What was the last number you wrote?"))
        XCTAssertEqual(recorder.waitForEnd(of: "t2"), .completed(TurnUsage(inputTokens: 10, outputTokens: 3, cacheReadTokens: 16618, cacheCreationTokens: 110)))
        XCTAssertEqual(recorder.turn("t2").first, .textDelta("1"))
    }

    func testAUsageLimitEndsTheTurnWithItsCauseAndReset() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("claude-turn-usage-limit")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Plan my week"))
        guard case .failed(let failure)? = recorder.waitForEnd(of: "t1") else { return XCTFail("the turn did not fail") }
        XCTAssertEqual(failure.cause, .usageLimit)
        XCTAssertNotNil(failure.resetsAt)
        XCTAssertEqual(failure.details, "You've hit your session limit · resets 7:20pm (America/New_York)")
    }

    func testAPIKeyBillingIsRefusedBeforeItSpendsAnything() throws {
        let recorder = EventRecorder()
        let launcher = ScriptedLauncher("claude-api-key")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Hi"))
        guard case .failed(let failure)? = recorder.waitForEnd(of: "t1") else { return XCTFail("the turn did not fail") }
        XCTAssertEqual(failure.cause, .signedOut)
        XCTAssertEqual(failure.details, "apiKeySource: ANTHROPIC_API_KEY")
        XCTAssertTrue(recorder.wait { $0.contains(.ended) })
        XCTAssertFalse(session.isLive)
    }

    func testAProcessThatDiesMidTurnFailsTheTurnWithItsOwnWordsAndEndsTheSession() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("claude-exit-mid-turn")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Hi"))
        guard case .failed(let failure)? = recorder.waitForEnd(of: "t1") else { return XCTFail("the turn did not fail") }
        XCTAssertEqual(failure.cause, .signedOut)
        XCTAssertEqual(failure.details, "Error: Failed to authenticate: OAuth session expired and could not be refreshed")
        XCTAssertTrue(recorder.wait { $0.last == .ended })
        XCTAssertThrowsError(try session.send(TurnRequest(turnId: "t2", text: "Again")))
    }

    func testImagesTravelAsContentBlocks() throws {
        let launcher = ScriptedLauncher("claude-session-turns")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, events: { _ in })
        try session.send(TurnRequest(turnId: "t1", text: "What is this?", images: [.init(mime: "image/png", base64: "iVBORw0KGgo=")]))
        let user = try XCTUnwrap(launcher.processes[0].writes.first { $0["type"] == "user" })
        XCTAssertEqual(user["message"]?["content"], [["type": "text", "text": "What is this?"],
                                                     ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]]])
    }

    func testWithoutClaudeCodeTheSessionCannotStart() {
        XCTAssertThrowsError(try adapter(ScriptedLauncher(), binary: nil).session(threadId: thread, resume: nil, model: nil, events: { _ in })) {
            XCTAssertEqual(($0 as? ProviderFailure)?.cause, .providerUnavailable)
        }
    }
}
