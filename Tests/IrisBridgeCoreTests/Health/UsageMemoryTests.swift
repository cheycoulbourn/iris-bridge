import XCTest
@testable import IrisBridgeCore

private final class Clock { var now = Date(timeIntervalSince1970: 1_790_133_024) }

/// Contract §4: a usage limit is remembered until the provider's reset, six hours when it gives none, and
/// cleared by the next successful turn.
final class UsageMemoryTests: XCTestCase {
    func testAUsageLimitIsRememberedUntilTheResetTheProviderGave() {
        let clock = Clock()
        let memory = UsageMemory(now: { clock.now })
        let reset = clock.now.addingTimeInterval(3_600)
        memory.recordFailure(ProviderFailure(cause: .usageLimit, provider: "codex", resetsAt: reset))
        XCTAssertEqual(memory.current("codex").usage, .limited)
        XCTAssertEqual(memory.current("codex").resetsAt, reset)
        XCTAssertEqual(memory.current("codex").lastErrorCause, .usageLimit)
        XCTAssertEqual(memory.current("claude").usage, .unknown, "one provider's limit is not the other's")
        clock.now = reset
        XCTAssertEqual(memory.current("codex").usage, .unknown, "at the reset the helper no longer knows")
        XCTAssertNil(memory.current("codex").resetsAt)
    }

    func testWithNoResetTimeALimitIsAssumedForSixHoursAndNoTimeIsInvented() {
        let clock = Clock()
        let memory = UsageMemory(now: { clock.now })
        memory.recordFailure(ProviderFailure(cause: .usageLimit, provider: "claude"))
        XCTAssertEqual(memory.current("claude").usage, .limited)
        XCTAssertNil(memory.current("claude").resetsAt)
        clock.now = clock.now.addingTimeInterval(6 * 3_600 - 1)
        XCTAssertEqual(memory.current("claude").usage, .limited)
        clock.now = clock.now.addingTimeInterval(1)
        XCTAssertEqual(memory.current("claude").usage, .unknown)
    }

    func testASuccessfulTurnClearsTheLimitAndTheLastCause() {
        let memory = UsageMemory(now: { Date(timeIntervalSince1970: 1_790_133_024) })
        memory.recordFailure(ProviderFailure(cause: .usageLimit, provider: "codex"))
        memory.recordSuccess("codex")
        let current = memory.current("codex")
        XCTAssertEqual(current.usage, .ok)
        XCTAssertNil(current.resetsAt)
        XCTAssertNil(current.lastErrorCause)
    }

    func testOtherFailuresNameTheCauseWithoutTouchingUsageAndACancelIsNotRemembered() {
        let memory = UsageMemory(now: { Date(timeIntervalSince1970: 1_790_133_024) })
        memory.recordSuccess("codex")
        memory.recordFailure(ProviderFailure(cause: .timeout, provider: "codex"))
        XCTAssertEqual(memory.current("codex").usage, .ok)
        XCTAssertEqual(memory.current("codex").lastErrorCause, .timeout)
        memory.recordFailure(ProviderFailure(cause: .cancelled, provider: "codex"))
        XCTAssertEqual(memory.current("codex").lastErrorCause, .timeout)
    }

    func testVersionIsReadFromEachCLIsOwnWording() {
        XCTAssertEqual(ProviderHealth.version(from: "2.1.274 (Claude Code)\n"), "2.1.274")
        XCTAssertEqual(ProviderHealth.version(from: "codex-cli 0.155.0-alpha.9.2\n"), "0.155.0-alpha.9.2")
        XCTAssertEqual(ProviderHealth.version(from: "command not found"), "")
    }

    func testHealthJSONLeavesOutWhatNobodyReported() {
        let quiet = ProviderHealth(installed: true, signedIn: true, account: "Max", cliVersion: "2.1.274", usage: .ok).json
        XCTAssertEqual(Set(quiet.keys), ["installed", "signedIn", "account", "cliVersion", "usage"])
        let limited = ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "0.155.0-alpha.9.2", usage: .limited,
                                     resetsAt: Date(timeIntervalSince1970: 1_790_426_460), lastErrorCause: .usageLimit).json
        XCTAssertEqual(limited["usage"] as? String, "limited")
        XCTAssertEqual(limited["resetsAt"] as? String, "2026-09-26T12:41:00Z")
        XCTAssertEqual(limited["lastErrorCause"] as? String, "usageLimit")
        let unchecked = ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "2.1.274", usage: .unknown, signInChecked: false).json
        XCTAssertEqual(Set(unchecked.keys), ["installed", "signedIn", "account", "cliVersion", "usage", "signInChecked"])
        XCTAssertEqual(unchecked["signInChecked"] as? Bool, false)
    }
}
