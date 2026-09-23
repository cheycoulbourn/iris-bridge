import XCTest
@testable import IrisBridgeCore

/// Recorded provider output in, one cause out (I1). Where each fixture came from is in Fixtures/README.md.
final class ProviderOutputTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - Codex

    func testCodexUsageLimitRecordedOnThisMacNamesTheCauseAndTheReset() {
        let failure = ProviderOutput.codexFailure(Fixture.result("codex-usage-limit"), timeZone: newYork)
        XCTAssertEqual(failure.cause, .usageLimit)
        XCTAssertEqual(failure.provider, "codex")
        XCTAssertEqual(failure.resetsAt, Date(timeIntervalSince1970: 1_790_426_460)) // 2026-09-26T12:41:00Z
        XCTAssertEqual(failure.details, "You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 26th, 2026 8:41 AM.")
    }

    func testCodexDroppedStreamIsProviderUnavailable() {
        let failure = ProviderOutput.codexFailure(Fixture.result("codex-disconnected"))
        XCTAssertEqual(failure.cause, .providerUnavailable)
        XCTAssertNil(failure.resetsAt)
        XCTAssertTrue(failure.details?.hasPrefix("stream disconnected before completion") ?? false)
    }

    func testCodexRefreshTokenFailureIsSignedOut() {
        XCTAssertEqual(ProviderOutput.codexFailure(Fixture.result("codex-signed-out")).cause, .signedOut)
    }

    func testCodexThatPrintedOnlyToStderrKeepsItsWords() {
        let failure = ProviderOutput.codexFailure(Fixture.result("codex-no-events"))
        XCTAssertEqual(failure.cause, .internal)
        XCTAssertEqual(failure.details, "Error: fixture failure before any event was printed")
    }

    // MARK: - Claude

    func testClaudeSessionLimitResetsAtTheTimeInTheZoneClaudeNames() {
        // The Mac's zone is UTC here to prove the zone in Claude's own words wins.
        let failure = ProviderOutput.claudeFailure(Fixture.result("claude-session-limit"),
                                                   now: Date(timeIntervalSince1970: 1_790_172_000), timeZone: utc) // 10:00 New York
        XCTAssertEqual(failure.cause, .usageLimit)
        XCTAssertEqual(failure.provider, "claude")
        XCTAssertEqual(failure.resetsAt, Date(timeIntervalSince1970: 1_790_205_600)) // 7:20 PM New York = 23:20 UTC
        XCTAssertEqual(failure.details, "You've hit your session limit · resets 7:20pm (America/New_York)")
    }

    func testClaudeResetThatAlreadyPassedTodayIsTomorrow() {
        let failure = ProviderOutput.claudeFailure(Fixture.result("claude-session-limit"),
                                                   now: Date(timeIntervalSince1970: 1_790_208_000), timeZone: utc) // 20:00 New York
        XCTAssertEqual(failure.resetsAt, Date(timeIntervalSince1970: 1_790_292_000))
    }

    func testClaudeExpiredSignInIsSignedOut() {
        let failure = ProviderOutput.claudeFailure(Fixture.result("claude-oauth-expired"))
        XCTAssertEqual(failure.cause, .signedOut)
        XCTAssertNil(failure.resetsAt)
        XCTAssertEqual(failure.details, "Failed to authenticate: OAuth session expired and could not be refreshed")
    }

    func testClaudeRevokedTokenIsReadFromTheTextWhenThereIsNoErrorCode() {
        XCTAssertEqual(ProviderOutput.claudeFailure(Fixture.result("claude-token-revoked")).cause, .signedOut)
    }

    func testClaudeOverloadedIsProviderUnavailable() {
        XCTAssertEqual(ProviderOutput.claudeFailure(Fixture.result("claude-overloaded")).cause, .providerUnavailable)
    }

    func testClaudeOfflineIsProviderUnavailable() {
        XCTAssertEqual(ProviderOutput.claudeFailure(Fixture.result("claude-offline")).cause, .providerUnavailable)
    }

    func testClaudeModelThatNeedsCreditsIsAModelProblemNotAUsageLimit() {
        let failure = ProviderOutput.claudeFailure(Fixture.result("claude-usage-credits"))
        XCTAssertEqual(failure.cause, .modelUnavailable)
        XCTAssertNil(failure.resetsAt)
    }

    func testClaudeThatPrintedOnlyToStderrKeepsItsWords() {
        let failure = ProviderOutput.claudeFailure(Fixture.result("claude-no-output"))
        XCTAssertEqual(failure.cause, .internal)
        XCTAssertEqual(failure.details, "Error: fixture failure before any event was printed")
    }

    func testARunThatPrintedNothingSaysSo() {
        let failure = ProviderOutput.claudeFailure(ProcessResult(status: 1, stdout: "", stderr: ""))
        XCTAssertEqual(failure.cause, .internal)
        XCTAssertEqual(failure.details, "Claude Code exited with status 1 and printed no reason.")
        XCTAssertEqual(ProviderOutput.codexFailure(ProcessResult(status: 2, stdout: "", stderr: "")).details,
                       "Codex exited with status 2 and printed no reason.")
    }

    // MARK: - Shared

    func testDetailsKeepTheLast2000CharactersOfStderr() {
        let noise = String(repeating: "x", count: 5_000) + "THE END"
        let failure = ProviderOutput.codexFailure(ProcessResult(status: 1, stdout: "", stderr: noise))
        XCTAssertEqual(failure.details?.count, 2_000)
        XCTAssertTrue(failure.details?.hasSuffix("THE END") ?? false)
    }

    func testLooseStdoutLinesAreKeptWhenThereIsNothingElse() {
        let failure = ProviderOutput.claudeFailure(ProcessResult(status: 1, stdout: "error: unknown option '--safe-mode'\n", stderr: ""))
        XCTAssertEqual(failure.details, "error: unknown option '--safe-mode'")
    }

    func testClassifyReadsEachCauseFromTheProvidersWords() {
        let table: [(String, FailureCause)] = [
            ("You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 26th, 2026 8:41 AM.", .usageLimit),
            ("You've hit your session limit · resets 7:20pm (America/New_York)", .usageLimit),
            ("Failed to authenticate: OAuth session expired and could not be refreshed", .signedOut),
            ("Failed to authenticate. API Error: 401 OAuth access token has been revoked.", .signedOut),
            ("API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment.", .providerUnavailable),
            ("API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)", .providerUnavailable),
            ("stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)", .providerUnavailable),
            ("Fable 5 requires usage credits. Run /usage-credits to continue or switch models with /model.", .modelUnavailable),
            ("The 'gpt-nonexistent' model is not supported when using Codex with a ChatGPT account.", .modelUnavailable),
            ("An image in the conversation exceeds the dimension limit for many-image requests (2000px). Start a new session with fewer images.", .internal),
            ("", .internal),
        ]
        for (text, cause) in table { XCTAssertEqual(ProviderOutput.classify(text), cause, text) }
    }

    func testEventsSkipLinesThatAreNotJSONObjects() {
        XCTAssertEqual(ProviderOutput.events("warning: noise\n{\"type\":\"turn.started\"}\n{not json").count, 1)
    }
}
