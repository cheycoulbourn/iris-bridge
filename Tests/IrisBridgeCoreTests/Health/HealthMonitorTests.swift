import XCTest
@testable import IrisBridgeCore

private final class ScriptedRunner: ProcessRunner {
    var signedIn = true
    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        if args.contains("--version") { return ProcessResult(status: 0, stdout: args[0].hasSuffix("claude") ? "2.1.274 (Claude Code)" : "codex-cli 0.155.0-alpha.9.2", stderr: "") }
        if args.contains("auth") {
            return ProcessResult(status: 0, stdout: signedIn ? #"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"# : #"{"loggedIn":false}"#, stderr: "")
        }
        return ProcessResult(status: 0, stdout: "", stderr: "Logged in using ChatGPT")
    }
}

final class HealthMonitorTests: XCTestCase {
    private var settings: URL!
    private var runner: ScriptedRunner!
    private var outbox: FakeOutbox!
    private var monitor: HealthMonitor!

    override func setUp() {
        settings = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        runner = ScriptedRunner()
        outbox = FakeOutbox()
        let providers = ProviderService(runner: runner, executableLookup: { "/usr/local/bin/\($0)" })
        monitor = HealthMonitor(providers: providers, settingsFile: settings)
        monitor.outbox = outbox
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
