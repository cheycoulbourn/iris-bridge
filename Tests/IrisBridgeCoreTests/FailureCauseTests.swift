import XCTest
@testable import IrisBridgeCore

/// The cause vocabulary and the error sentence older apps show as they stand (contract §1, spec §9.2).
final class FailureCauseTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let now = Date(timeIntervalSince1970: 1_790_172_000) // 2026-09-23 10:00 New York

    func testTheWireNamesAreTheContractsList() {
        XCTAssertEqual(FailureCause.allCases.map(\.rawValue),
                       ["signedOut", "usageLimit", "providerUnavailable", "modelUnavailable", "timeout", "cancelled",
                        "busy", "deviceRevoked", "badRequest", "internal"])
    }

    func testStatusCodesTheRouterAlreadySendsMapToACause() {
        XCTAssertEqual(FailureCause.forStatus(400), .badRequest)
        XCTAssertEqual(FailureCause.forStatus(401), .deviceRevoked)
        XCTAssertEqual(FailureCause.forStatus(403), .badRequest)
        XCTAssertEqual(FailureCause.forStatus(404), .badRequest)
        XCTAssertEqual(FailureCause.forStatus(409), .busy)
        XCTAssertEqual(FailureCause.forStatus(413), .badRequest)
        XCTAssertEqual(FailureCause.forStatus(429), .busy)
        XCTAssertEqual(FailureCause.forStatus(500), .internal)
        XCTAssertEqual(FailureCause.forStatus(502), .internal)
        XCTAssertEqual(FailureCause.forStatus(504), .timeout)
    }

    func testUsageLimitSentenceNamesTheResetOnTheMacsClock() {
        let later = ProviderFailure(cause: .usageLimit, provider: "claude", resetsAt: Date(timeIntervalSince1970: 1_790_193_600))
        XCTAssertEqual(later.sentence(now: now, timeZone: newYork), "Claude's usage limit is reached until 4:00 PM.")
        let days = ProviderFailure(cause: .usageLimit, provider: "codex", resetsAt: Date(timeIntervalSince1970: 1_790_426_460))
        XCTAssertEqual(days.sentence(now: now, timeZone: newYork), "ChatGPT's usage limit is reached until Sep 26, 8:41 AM.")
        XCTAssertEqual(ProviderFailure(cause: .usageLimit, provider: "codex").sentence(now: now, timeZone: newYork),
                       "ChatGPT's usage limit is reached. Try again later.")
    }

    func testSignedOutSentencesGiveTheCommandFromTheSpec() {
        XCTAssertEqual(ProviderFailure(cause: .signedOut, provider: "claude").sentence(),
                       "Claude is signed out on your Mac. On the Mac, open Terminal and run `claude auth login`.")
        XCTAssertEqual(ProviderFailure(cause: .signedOut, provider: "codex").sentence(),
                       "ChatGPT is signed out on your Mac. On the Mac, open Terminal and run `codex login`.")
    }

    func testAnInternalFailureQuotesTheProviderOnOneShortLine() {
        let failure = ProviderFailure(cause: .internal, provider: "codex", details: "line one\nline two")
        XCTAssertEqual(failure.sentence(), "Codex could not finish. Nothing was changed. It said: line one line two")
        XCTAssertEqual(ProviderFailure(cause: .internal, provider: "claude").sentence(), "Claude Code could not finish. Nothing was changed.")
    }

    func testAMessageOverrideWins() {
        let failure = ProviderFailure(cause: .signedOut, provider: "claude", message: "Claude selected API-key billing.")
        XCTAssertEqual(failure.sentence(), "Claude selected API-key billing.")
    }

    func testDetailsAreTrimmedCappedAndDroppedWhenEmpty() {
        XCTAssertNil(ProviderFailure(cause: .internal, provider: "claude", details: "  \n ").details)
        XCTAssertEqual(ProviderFailure(cause: .internal, provider: "claude", details: " kept \n").details, "kept")
        XCTAssertEqual(ProviderFailure(cause: .internal, provider: "claude",
                                       details: String(repeating: "a", count: 3_000)).details?.count, 2_000)
    }

    func testTheBodyKeepsErrorAndAddsTheNewFields() {
        let body = ProviderFailure(cause: .usageLimit, provider: "codex", details: "You’ve hit your usage limit.",
                                   resetsAt: Date(timeIntervalSince1970: 1_790_426_460)).body(now: now, timeZone: newYork)
        XCTAssertEqual(body["error"] as? String, "ChatGPT's usage limit is reached until Sep 26, 8:41 AM.")
        XCTAssertEqual(body["cause"] as? String, "usageLimit")
        XCTAssertEqual(body["provider"] as? String, "codex")
        XCTAssertEqual(body["details"] as? String, "You’ve hit your usage limit.")
        XCTAssertEqual(body["resetsAt"] as? String, "2026-09-26T12:41:00Z")
        let bare = ProviderFailure(cause: .timeout, provider: "codex").body()
        XCTAssertNil(bare["resetsAt"])
        XCTAssertNil(bare["details"])
    }

    func testOnlyATimeoutMovesOffTheBadGatewayStatus() {
        for cause in FailureCause.allCases {
            XCTAssertEqual(ProviderFailure(cause: cause, provider: "claude").httpStatus, cause == .timeout ? 504 : 502, cause.rawValue)
        }
    }
}
