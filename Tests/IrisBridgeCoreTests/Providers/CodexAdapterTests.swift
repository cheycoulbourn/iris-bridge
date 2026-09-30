import XCTest
@testable import IrisBridgeCore

/// The Codex adapter against transcripts: `codex-exec-usage-limit` is recorded (spike q4-a, Codex
/// 0.155.0-alpha.9.2); `codex-exec-tool-call` and `codex-exec-resume` follow Codex's documented exec JSON output
/// and are unverified until the spike's Codex retry (S7). Fixtures/README.md says which is which.
final class CodexAdapterTests: XCTestCase {
    private let thread = "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77"

    private func adapter(_ launcher: ScriptedLauncher, binary: String? = "/Applications/Codex.app/Contents/Resources/codex") -> CodexAdapter {
        CodexAdapter(setup: CodexSetup(binary: { binary }, helperBinary: "/Applications/Iris Bridge/iris-bridge", root: URL(fileURLWithPath: "/tmp/iris root"),
                                       port: 48731, workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("iris-sessions")),
                     launcher: launcher,
                     health: { ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "0.155.0-alpha.9.2", usage: .unknown) })
    }

    func testTheFirstTurnUsesTheVerifiedFlagsAndStartsWithTheIrisPrompt() throws {
        let launcher = ScriptedLauncher("codex-exec-tool-call")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: "gpt-5-codex", events: { _ in })
        try session.send(TurnRequest(turnId: "t1", text: "What is planned this week?"))
        let arguments = launcher.commands[0].arguments
        XCTAssertEqual(Array(arguments.prefix(7)), ["/Applications/Codex.app/Contents/Resources/codex", "exec", "--json", "--ignore-user-config",
                                                    "--skip-git-repo-check", "--sandbox", "read-only"])
        XCTAssertTrue(arguments.contains(#"web_search="disabled""#))
        let enabled = "mcp_servers.iris.enabled_tools=[\(IrisToolCatalog.all.map { CodexCommandLine.toml($0.name) }.joined(separator: ","))]"
        XCTAssertTrue(arguments.contains(enabled))
        let approvals = arguments.filter { $0.contains("approval_mode=") }
        XCTAssertEqual(approvals, IrisToolCatalog.all.map { "mcp_servers.iris.tools.\($0.name).approval_mode=\"approve\"" })
        XCTAssertFalse(arguments.contains { $0.contains("default_tools_approval_mode") }, "unknown future tools must not be trusted")
        XCTAssertFalse(arguments.contains { $0.contains("iris.tools.approval.") }, "Claude's permission prompt is not a Codex tool")
        XCTAssertTrue(arguments.contains(#"mcp_servers.iris.command="/Applications/Iris Bridge/iris-bridge""#))
        XCTAssertTrue(arguments.contains(#"mcp_servers.iris.args=["mcp","--thread","\#(thread)","--root","/tmp/iris root","--port","48731"]"#))
        XCTAssertEqual(arguments.enumerated().filter { $0.element == "--disable" }.map { arguments[$0.offset + 1] }, CodexCommandLine.disabledFeatures)
        XCTAssertTrue(arguments.contains(#"model="gpt-5-codex""#))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("model_reasoning_effort=") }, "Automatic sends no config")
        XCTAssertEqual(arguments.last, "-")
        XCTAssertFalse(arguments.contains("--ephemeral"))
        XCTAssertFalse(arguments.contains("js_repl"), "removed in Codex 0.155")
        let prompt = String(decoding: try XCTUnwrap(launcher.commands[0].input), as: UTF8.self)
        XCTAssertTrue(prompt.hasPrefix(IrisPrompt.system + "\n\n"))
        XCTAssertTrue(prompt.hasSuffix("What is planned this week?"))
    }

    func testAToolCallTurnReportsItsToolsAndItsReplyAndTheThreadIdToResumeBy() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("codex-exec-tool-call")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "What is planned this week?"))
        XCTAssertEqual(recorder.waitForEnd(of: "t1"), .completed(TurnUsage(inputTokens: 24763, outputTokens: 122, cacheReadTokens: 24448)))
        XCTAssertEqual(recorder.turn("t1"), [
            .thinking,
            .toolStarted(toolUseId: "item_1", name: "iris_list_posts", summary: "Reading your posts"),
            .toolFinished(toolUseId: "item_1", name: "iris_list_posts", ok: true, summary: "Done"),
            .toolStarted(toolUseId: "item_2", name: "iris_create_task", summary: "Adding a task"),
            .toolFinished(toolUseId: "item_2", name: "iris_create_task", ok: false, summary: "Iris is not open on a paired device."),
            .textDelta("Nothing is planned this week."),
            .completed(TurnUsage(inputTokens: 24763, outputTokens: 122, cacheReadTokens: 24448))
        ])
        XCTAssertEqual(recorder.all.first, .session(id: "0199a213-81c0-7800-8aa1-bbab2a035a53"))
        XCTAssertEqual(session.sessionId, "0199a213-81c0-7800-8aa1-bbab2a035a53")
    }

    /// Unverified until S7: the resume command line is `codex exec resume --help`'s, and the fixture is from the docs.
    func testTheNextTurnResumesByThreadId() throws {
        let recorder = EventRecorder()
        let launcher = ScriptedLauncher("codex-exec-tool-call", "codex-exec-resume")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "What is planned this week?"))
        _ = recorder.waitForEnd(of: "t1")
        try session.send(TurnRequest(turnId: "t2", text: "What did I just ask?"))
        XCTAssertEqual(recorder.waitForEnd(of: "t2"), .completed(TurnUsage(inputTokens: 25010, outputTokens: 14, cacheReadTokens: 24832)))
        let resumed = launcher.commands[1].arguments
        XCTAssertEqual(Array(resumed.prefix(9)), ["/Applications/Codex.app/Contents/Resources/codex", "exec", "resume", "0199a213-81c0-7800-8aa1-bbab2a035a53",
                                                  "--json", "--ignore-user-config", "--skip-git-repo-check", "-c", #"sandbox_mode="read-only""#])
        XCTAssertFalse(resumed.contains("--sandbox"))
        XCTAssertTrue(resumed.contains(#"mcp_servers.iris.tools.iris_create_post_draft.approval_mode="approve""#), "resumed turns keep the narrowly trusted relay")
        XCTAssertTrue(resumed.contains { $0.hasPrefix("mcp_servers.iris.args=") }, "the Iris server goes with every run")
        XCTAssertEqual(String(decoding: launcher.commands[1].input ?? Data(), as: UTF8.self), "What did I just ask?", "the system prompt is sent once")
        XCTAssertEqual(recorder.all.filter { if case .session = $0 { return true }; return false }.count, 1, "the same thread id is not reported twice")
    }

    func testAStoredThreadIsResumedFromTheFirstTurn() throws {
        let launcher = ScriptedLauncher("codex-exec-resume")
        let session = try adapter(launcher).session(threadId: thread, resume: "0199a213-81c0-7800-8aa1-bbab2a035a53", model: nil, events: { _ in })
        try session.send(TurnRequest(turnId: "t1", text: "And now?"))
        XCTAssertEqual(launcher.commands[0].arguments[2], "resume")
    }

    func testAUsageLimitFailsTheTurnWithItsReset() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("codex-exec-usage-limit")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Hi"))
        guard case .failed(let failure)? = recorder.waitForEnd(of: "t1") else { return XCTFail("the turn did not fail") }
        XCTAssertEqual(failure.cause, .usageLimit)
        XCTAssertNotNil(failure.resetsAt)
    }

    func testCancelStopsTheRun() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("codex-exec-hang")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Hi"))
        recorder.wait { $0.contains(.session(id: "0199a213-81c0-7800-8aa1-bbab2a035a53")) }
        session.cancel()
        XCTAssertEqual(recorder.waitForEnd(of: "t1"), .failed(ProviderFailure(cause: .cancelled, provider: "codex")))
    }

    func testTheRecordedCodexApprovalFailureIsReportedAsAToolFailure() throws {
        let recorder = EventRecorder()
        let session = try adapter(ScriptedLauncher("codex-exec-approval-required")).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "Synthetic transport test"))
        guard case .completed? = recorder.waitForEnd(of: "t1") else { return XCTFail("Codex did not finish explaining its tool failure") }
        XCTAssertTrue(recorder.turn("t1").contains(.toolFinished(toolUseId: "item_2", name: "iris_create_post_draft", ok: false,
                                                              summary: "MCP tool call requires approval, but approval policy is never")))
    }

    func testTheRecordedTrustedIrisToolCallsWorkOnNewAndResumedTurns() throws {
        let recorder = EventRecorder()
        let launcher = ScriptedLauncher("codex-exec-trusted-iris", "codex-exec-trusted-iris-resume")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        for turn in ["t1", "t2"] {
            try session.send(TurnRequest(turnId: turn, text: "Synthetic transport test"))
            guard case .completed? = recorder.waitForEnd(of: turn) else { return XCTFail("the recorded turn did not complete") }
            XCTAssertTrue(recorder.turn(turn).contains(.toolFinished(toolUseId: "item_2", name: "iris_create_post_draft", ok: true, summary: "Done")))
            XCTAssertTrue(recorder.turn(turn).contains { if case .textDelta(let text) = $0 { return text.contains("fixture-inbox") }; return false })
        }
        XCTAssertEqual(launcher.commands[1].arguments[2], "resume")
        XCTAssertEqual(session.sessionId, "0199a213-81c0-7800-8aa1-bbab2a035a53")
    }

    func testImagesArePassedAsFilesThatAreRemovedAfterwards() throws {
        let launcher = ScriptedLauncher("codex-exec-resume")
        let recorder = EventRecorder()
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "What is this?", images: [.init(mime: "image/png", base64: "iVBORw0KGgo=")]))
        _ = recorder.waitForEnd(of: "t1")
        let arguments = launcher.commands[0].arguments
        let file = try XCTUnwrap(arguments.firstIndex(of: "-i").map { arguments[$0 + 1] })
        XCTAssertTrue(file.hasSuffix("image-0.png"))
        XCTAssertTrue(recorder.wait { _ in !FileManager.default.fileExists(atPath: file) })
    }

    func testALateExitAndOutputCannotFinishOrPolluteTheNextTurn() throws {
        let launcher = ControlledCodexLauncher()
        let recorder = EventRecorder()
        let setup = CodexSetup(binary: { "/codex" }, helperBinary: "/iris-bridge", root: FileManager.default.temporaryDirectory,
                               port: 48731, workingDirectory: FileManager.default.temporaryDirectory)
        let session = try CodexAdapter(setup: setup, launcher: launcher, health: { ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "", usage: .unknown) })
            .session(threadId: thread, resume: nil, model: nil, events: recorder.record)
        try session.send(TurnRequest(turnId: "t1", text: "First"))
        launcher.runs[0].line(Data(#"{"type":"turn.completed","usage":{}}"#.utf8))
        XCTAssertEqual(recorder.waitForEnd(of: "t1"), .completed(TurnUsage()))
        try session.send(TurnRequest(turnId: "t2", text: "Second", images: [.init(mime: "image/png", base64: "iVBORw0KGgo=")]))
        let second = launcher.runs[1]
        let arguments = second.command.arguments
        let image = try XCTUnwrap(arguments.firstIndex(of: "-i").map { arguments[$0 + 1] })
        launcher.runs[0].line(Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"stale"}}"#.utf8))
        launcher.runs[0].exit(0, "")
        second.line(Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"fresh"}}"#.utf8))
        XCTAssertTrue(recorder.wait { $0.contains(.turn(turnId: "t2", .textDelta("fresh"))) })
        XCTAssertEqual(recorder.turn("t2"), [.textDelta("fresh")], "old exit must not fail the new turn")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image), "old exit must not delete the new turn's attachment")
        session.cancel()
        XCTAssertEqual(recorder.waitForEnd(of: "t2"), .failed(ProviderFailure(cause: .cancelled, provider: "codex")), "old exit must not clear the new process")
        XCTAssertTrue(recorder.wait { _ in !FileManager.default.fileExists(atPath: image) })
    }

    func testTOMLStringsAreEscaped() {
        XCTAssertEqual(CodexCommandLine.toml(#"a "quoted" \ path"#), #""a \"quoted\" \\ path""#)
    }

    /// Codex documents low/medium/high for `model_reasoning_effort`; the app's Claude-only xhigh and max fold
    /// into Codex's highest rather than being sent unmapped or refused (this stays unverified live, Task 13).
    func testAGivenEffortBecomesCodexsDocumentedConfigKey() throws {
        let launcher = ScriptedLauncher("codex-exec-tool-call")
        let session = try adapter(launcher).session(threadId: thread, resume: nil, model: nil, effort: "medium", events: { _ in })
        try session.send(TurnRequest(turnId: "t1", text: "Hi"))
        XCTAssertTrue(launcher.commands[0].arguments.contains(#"model_reasoning_effort="medium""#))
        XCTAssertEqual(session.effort, "medium")
    }

    func testXhighAndMaxMapToCodexsHighestDocumentedLevel() {
        XCTAssertEqual(CodexCommandLine.codexEffort("low"), "low")
        XCTAssertEqual(CodexCommandLine.codexEffort("medium"), "medium")
        XCTAssertEqual(CodexCommandLine.codexEffort("high"), "high")
        XCTAssertEqual(CodexCommandLine.codexEffort("xhigh"), "high")
        XCTAssertEqual(CodexCommandLine.codexEffort("max"), "high")
    }
}

private final class ControlledCodexLauncher: ProcessLauncher {
    final class Run: ProviderProcess {
        let command: ProviderCommand
        let line: (Data) -> Void
        let exit: (Int32, String) -> Void
        init(_ command: ProviderCommand, _ line: @escaping (Data) -> Void, _ exit: @escaping (Int32, String) -> Void) {
            self.command = command; self.line = line; self.exit = exit
        }
        func write(_ line: Data) {}
        func closeInput() {}
        func terminate() { exit(143, "") }
    }
    var runs: [Run] = []
    func launch(_ command: ProviderCommand, line: @escaping (Data) -> Void, exit: @escaping (Int32, String) -> Void) throws -> ProviderProcess {
        let run = Run(command, line, exit)
        runs.append(run)
        return run
    }
}
