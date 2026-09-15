import XCTest
@testable import IrisBridgeCore

private final class FakeRunner: ProcessRunner {
    var handler: ([String], String?) throws -> ProcessResult
    var calls: [[String]] = []
    init(_ handler: @escaping ([String], String?) throws -> ProcessResult) { self.handler = handler }
    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        calls.append(args); return try handler(args, input)
    }
}
private func result(_ stdout: String = "", stderr: String = "", status: Int32 = 0) -> ProcessResult { ProcessResult(status: status, stdout: stdout, stderr: stderr) }
private func lines(_ events: [[String: Any]]) -> String {
    events.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
}

final class ProvidersTests: XCTestCase {
    func testSubscriptionEnvironmentStripsKeys() {
        let env = ProviderService.subscriptionEnvironment(from: ["ANTHROPIC_API_KEY": "s", "CLAUDE_CODE_OAUTH_TOKEN": "s", "OPENAI_API_KEY": "s", "PATH": "normal"])
        XCTAssertEqual(env, ["PATH": "normal"])
    }
    func testClaudeStatusRequiresSubscription() {
        let runner = FakeRunner { _, _ in result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai","email":"e@x.com"}"#) }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" })
        XCTAssertTrue(service.status("claude").ready)
        XCTAssertEqual(service.status("claude").auth, "subscription")
        let keyRunner = FakeRunner { _, _ in result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"api_key"}"#) }
        XCTAssertFalse(ProviderService(runner: keyRunner, executableLookup: { _ in "/tool" }).status("claude").ready)
    }
    func testCodexStatusNeedsChatGPT() {
        XCTAssertFalse(ProviderService(runner: FakeRunner { _, _ in result(stderr: "Logged in using an API key") }, executableLookup: { _ in "/tool" }).status("codex").ready)
        XCTAssertTrue(ProviderService(runner: FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }, executableLookup: { _ in "/tool" }).status("codex").ready)
    }
    func testMissingExecutableReportsInstall() {
        let s = ProviderService(runner: FakeRunner { _, _ in result() }, executableLookup: { _ in nil }).status("claude")
        XCTAssertFalse(s.ready); XCTAssertEqual(s.message, "Install Claude Code on your Mac first.")
    }
    func testStatusIsCachedForSixtySeconds() {
        var now = Date(timeIntervalSince1970: 0)
        let runner = FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, now: { now })
        _ = service.status("codex"); _ = service.status("codex")
        XCTAssertEqual(runner.calls.count, 1)
        now = now.addingTimeInterval(61); _ = service.status("codex")
        XCTAssertEqual(runner.calls.count, 2)
    }
    func testClaudeGenerateReportsModelAndBlocksKeyBilling() throws {
        var source = "none"
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "claude-fable-5-1", "apiKeySource": source],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" })
        let output = try service.generate(MessageRequest(provider: "claude", message: "Hello"))
        XCTAssertEqual(output["model"] as? String, "claude-fable-5-1"); XCTAssertEqual(output["auth"] as? String, "subscription")
        source = "env"
        XCTAssertThrowsError(try service.generate(MessageRequest(provider: "claude", message: "Hello"))) { XCTAssertTrue("\($0)".contains("API-key")) }
    }
    func testClaudeUpdateRunsAtMostOncePerHour() throws {
        var now = Date(timeIntervalSince1970: 0)
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": "none"],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, now: { now })
        _ = try service.generate(MessageRequest(provider: "claude", message: "a"))
        _ = try service.generate(MessageRequest(provider: "claude", message: "b"))
        XCTAssertEqual(runner.calls.filter { $0.contains("install") }.count, 1)
        now = now.addingTimeInterval(3601)
        _ = try service.generate(MessageRequest(provider: "claude", message: "c"))
        XCTAssertEqual(runner.calls.filter { $0.contains("install") }.count, 2)
    }
    func testCodexPlanModeSuppressesProposal() throws {
        let reply = #"{"reply":"Ready","proposal":{"title":"No write"}}"#
        let runner = FakeRunner { args, _ in
            if args.contains("login") { return result(stderr: "Logged in using ChatGPT") }
            return result(lines([["type": "item.completed", "item": ["type": "agent_message", "text": reply]], ["type": "turn.completed"]]))
        }
        let output = try ProviderService(runner: runner, executableLookup: { _ in "/tool" }).generate(MessageRequest(provider: "codex", message: "Hi", planMode: true))
        XCTAssertTrue(output["proposal"] is NSNull); XCTAssertEqual(output["auth"] as? String, "subscription")
    }
    func testCanceledRequestDoesNotLaunch() {
        let runner = ForegroundProcessRunner()
        runner.markCanceled("cancel-1")
        XCTAssertThrowsError(try runner.run(["/usr/bin/true"], input: nil, cwd: nil, timeout: 5, requestID: "cancel-1")) { XCTAssertEqual($0 as? BridgeError, .canceled) }
    }
}
