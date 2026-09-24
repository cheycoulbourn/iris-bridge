import XCTest
@testable import IrisBridgeCore

private final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    /// What `codex login status` answers.
    enum CodexSignIn { case chatGPT, apiKey, timesOut }
    private var _signedIn = true, _checkTimesOut = false, _claudeChecks = 0, _codex = CodexSignIn.chatGPT
    var signedIn: Bool { get { lock.lock(); defer { lock.unlock() }; return _signedIn } set { lock.lock(); _signedIn = newValue; lock.unlock() } }
    /// Claude's sign-in check times out, the way it does on a Mac too busy to start a CLI in time.
    var checkTimesOut: Bool { get { lock.lock(); defer { lock.unlock() }; return _checkTimesOut } set { lock.lock(); _checkTimesOut = newValue; lock.unlock() } }
    var codex: CodexSignIn { get { lock.lock(); defer { lock.unlock() }; return _codex } set { lock.lock(); _codex = newValue; lock.unlock() } }
    var claudeChecks: Int { lock.lock(); defer { lock.unlock() }; return _claudeChecks }
    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        if args.contains("--version") { return ProcessResult(status: 0, stdout: args[0].hasSuffix("claude") ? "2.1.274 (Claude Code)" : "codex-cli 0.155.0-alpha.9.2", stderr: "") }
        if args.contains("auth") {
            lock.lock(); _claudeChecks += 1; lock.unlock()
            if checkTimesOut { throw BridgeError.timeout }
            return ProcessResult(status: 0, stdout: signedIn ? #"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"# : #"{"loggedIn":false}"#, stderr: "")
        }
        switch codex {
        case .chatGPT: return ProcessResult(status: 0, stdout: "", stderr: "Logged in using ChatGPT")
        case .apiKey: return ProcessResult(status: 0, stdout: "", stderr: "Logged in using an API key - sk-proj-***")
        case .timesOut: throw BridgeError.timeout
        }
    }
}

final class HealthMonitorTests: XCTestCase {
    private var settings: URL!
    private var runner: ScriptedRunner!
    private var outbox: FakeOutbox!
    private var monitor: HealthMonitor!
    private let clock = TestClock()

    override func setUp() {
        settings = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        runner = ScriptedRunner()
        outbox = FakeOutbox()
        let clock = self.clock
        let providers = ProviderService(runner: runner, executableLookup: { "/usr/local/bin/\($0)" }, now: { clock.now })
        providers.signInRetryPause = 0
        monitor = HealthMonitor(providers: providers, settingsFile: settings)
        monitor.outbox = outbox
    }

    /// Waits, off the main thread, until the report says what `condition` wants.
    private func eventually(_ what: String, _ condition: @escaping (JSONValue) -> Bool) {
        let done = expectation(description: what)
        DispatchQueue.global().async { while !condition(self.monitor.report()) { Thread.sleep(forTimeInterval: 0.01) }; done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func settle() {
        monitor.refresh()
        let done = expectation(description: "checked")
        DispatchQueue.global().async { while self.monitor.report()["checked"] != true { Thread.sleep(forTimeInterval: 0.01) }; done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testBeforeTheFirstCheckNothingIsClaimedAndNothingIsRefused() {
        XCTAssertEqual(monitor.report()["checked"], false)
        XCTAssertEqual(monitor.report()["claude"]?["signedIn"], false)
        XCTAssertNil(monitor.readiness(.claude), "an unchecked provider is tried, not refused")
    }

    func testTheReportCarriesSignInVersionAndTheAccountsConnectorsAndCommands() {
        settle()
        let report = monitor.report()
        XCTAssertEqual(report["helperVersion"]?.stringValue, BridgeVersion.current)
        XCTAssertEqual(report["claude"]?["signedIn"], true)
        XCTAssertEqual(report["claude"]?["account"], "Max")
        XCTAssertEqual(report["claude"]?["cliVersion"], "2.1.274")
        XCTAssertEqual(report["codex"]?["cliVersion"], "0.155.0-alpha.9.2")
        XCTAssertEqual(outbox.broadcasts.last?["type"], "health.changed")
        monitor.observe(.claude, .catalog(commands: [["name": "brainstorm", "description": "Brainstorm", "argumentHint": ""]], connectors: MCPStatusFixture.table))
        XCTAssertEqual(monitor.report()["claude"]?["connectors"]?.arrayValue?.map { $0["name"] }, ["Gmail", "Google Calendar", "Notion"])
        XCTAssertEqual(monitor.report()["claude"]?["commands"]?.arrayValue?.first?["name"], "brainstorm")
        let changes = outbox.broadcasts.count
        monitor.observe(.claude, .catalog(commands: [["name": "brainstorm", "description": "Brainstorm", "argumentHint": ""]], connectors: MCPStatusFixture.table))
        XCTAssertEqual(outbox.broadcasts.count, changes, "the same catalog again sends nothing")
    }

    func testASignedOutProviderIsRefusedBeforeATurnStarts() {
        runner.signedIn = false
        settle()
        XCTAssertEqual(monitor.readiness(.claude)?.cause, .signedOut)
        XCTAssertNil(monitor.readiness(.codex))
    }

    func testASignInTheMacCouldNotCheckIsTriedNotRefusedOnceASubscriptionWasConfirmed() {
        settle()
        runner.checkTimesOut = true
        clock.advance(ProviderService.signedInLifetime + 1)
        monitor.refresh()
        eventually("claude unchecked") { $0["claude"]?["signInChecked"] == false }
        XCTAssertNil(monitor.readiness(.claude), "a busy Mac is not a signed-out one")
        let claude = monitor.report()["claude"]
        XCTAssertEqual(claude?["signedIn"], true, "older apps read signedIn: false as signed out")
        XCTAssertEqual(claude?["account"], "")
        XCTAssertEqual(runner.claudeChecks, 3, "the first check, then one check and its one quick retry; health does not check again")
        XCTAssertNil(monitor.report()["codex"]?["signInChecked"], "a finished check adds nothing to the report")
    }

    /// With no subscription sign-in confirmed, a check that cannot finish has not ruled out an API key. Refused,
    /// and not as signed out: the report the app reads says `signedIn: true`, because the app shows false as
    /// "not signed in" and refuses the send itself, and a busy Mac is not a signed-out one.
    func testASignInTheMacCouldNeverCheckIsRefusedButNotAsSignedOut() {
        runner.checkTimesOut = true
        settle()
        let failure = monitor.readiness(.claude)
        XCTAssertEqual(failure?.cause, .providerUnavailable)
        XCTAssertEqual(failure?.sentence(), "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment.")
        XCTAssertEqual(monitor.report()["claude"]?["signedIn"], true, "the app shows signedIn: false as signed out")
        XCTAssertEqual(monitor.report()["claude"]?["signInChecked"], false)
    }

    /// For Codex the sign-in check is the only thing that refuses API-key billing: a key `codex login
    /// --with-api-key` saved survives a clean environment, and neither CodexStream nor CodexAdapter sees the auth
    /// mode. thread.send must not start a Codex run because the check timed out.
    func testACodexAPIKeySetupWhoseCheckTimesOutIsRefusedBeforeATurn() {
        runner.codex = .timesOut
        settle()
        XCTAssertEqual(monitor.readiness(.codex)?.cause, .providerUnavailable, "never checked: no turn")
        XCTAssertEqual(monitor.report()["codex"]?["signedIn"], true, "shown as not signed out, and still refused")
        XCTAssertEqual(monitor.report()["codex"]?["signInChecked"], false)

        runner.codex = .apiKey
        monitor.refresh()
        eventually("codex checked") { $0["codex"]?["signInChecked"] == nil }
        XCTAssertEqual(monitor.readiness(.codex)?.cause, .signedOut, "an API key is not a subscription sign-in")
        XCTAssertEqual(monitor.report()["codex"]?["signedIn"], false, "a finished check that found an API key is shown as signed out")

        runner.codex = .timesOut
        clock.advance(ProviderService.signedOutLifetime + 1)
        monitor.refresh()
        eventually("codex unchecked again") { $0["codex"]?["signInChecked"] == false }
        let failure = monitor.readiness(.codex)
        XCTAssertEqual(failure?.cause, .providerUnavailable, "the last finished answer was an API key: no turn")
        XCTAssertEqual(failure?.sentence(), "Couldn't check ChatGPT's sign-in just now — the Mac may be busy. Try again in a moment.")
    }

    func testACodexChatGPTSignInWhoseLaterCheckTimesOutIsStillTried() {
        settle()
        runner.codex = .timesOut
        clock.advance(ProviderService.signedInLifetime + 1)
        monitor.refresh()
        eventually("codex unchecked") { $0["codex"]?["signInChecked"] == false }
        XCTAssertNil(monitor.readiness(.codex))
        XCTAssertEqual(monitor.report()["codex"]?["signedIn"], true)
    }

    func testSigningInAfterARefusalIsPickedUpWithoutWaitingForTheTimer() {
        runner.signedIn = false
        settle()
        // The owner signs in on the Mac after the last check. The monitor's timer is not running in this test,
        // so the check that notices is the one the refusal asks for.
        runner.signedIn = true
        clock.advance(11)
        XCTAssertEqual(monitor.readiness(.claude)?.cause, .signedOut)
        eventually("signed in") { $0["claude"]?["signedIn"] == true }
        XCTAssertNil(monitor.readiness(.claude))
    }

    func testUsageFollowsWhatTurnsReport() {
        settle()
        let reset = Date(timeIntervalSince1970: 1_790_205_600)
        monitor.observe(.claude, .usage(limited: true, resetsAt: reset))
        settle()
        let limited = expectation(description: "limited")
        DispatchQueue.global().async { while self.monitor.report()["claude"]?["usage"] != "limited" { Thread.sleep(forTimeInterval: 0.01) }; limited.fulfill() }
        wait(for: [limited], timeout: 5)
        XCTAssertEqual(monitor.report()["claude"]?["resetsAt"], "2026-09-23T23:20:00Z")
        monitor.observe(.claude, .turn(turnId: "t1", .completed(TurnUsage())))
        let ok = expectation(description: "ok")
        DispatchQueue.global().async { while self.monitor.report()["claude"]?["usage"] != "ok" { Thread.sleep(forTimeInterval: 0.01) }; ok.fulfill() }
        wait(for: [ok], timeout: 5)
        monitor.observe(.claude, .turn(turnId: "t2", .failed(ProviderFailure(cause: .busy, provider: "claude"))))
        settle()
        XCTAssertNil(monitor.report()["claude"]?["lastErrorCause"], "a refused message says nothing about Claude")
    }

    func testPreAllowedMCPToolsAreReported() throws {
        try Data(#"{"permissions":{"allow":["Bash(ls:*)","mcp__claude_ai_Gmail__send_message","mcp__iris__iris_list_posts"],"deny":[]}}"#.utf8).write(to: settings)
        XCTAssertEqual(monitor.preAllowedTools(), ["mcp__claude_ai_Gmail__send_message", "mcp__iris__iris_list_posts"])
        XCTAssertEqual(monitor.report()["claude"]?["preAllowedTools"]?.arrayValue?.count, 2)
    }
}

/// The clock `ProviderService` keeps its sign-in answers by. Read from the monitor's queue, so it is locked.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}
