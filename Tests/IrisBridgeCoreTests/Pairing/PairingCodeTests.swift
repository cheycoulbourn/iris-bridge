import XCTest
@testable import IrisBridgeCore

final class PairingCodeTests: XCTestCase {
    let fingerprint = String(repeating: "ab", count: 32)
    let expectedProof = "31275f68b987c913ae120f3ad546855e6ab15401718b42de86e8f69fdd1ce00d"

    func testProofMatchesOpenSSLVector() {
        XCTAssertEqual(PairingProof.compute(code: "482913", fingerprint: fingerprint), expectedProof)
    }
    func testIssueProducesSixDigits() {
        let store = PairingCodeStore()
        let issued = store.issue()
        XCTAssertEqual(issued.code.count, 6)
        XCTAssertTrue(issued.code.allSatisfy(\.isNumber))
    }
    func testCorrectProofIsAcceptedOnce() {
        let store = PairingCodeStore(generator: { "482913" })
        _ = store.issue()
        XCTAssertEqual(store.redeem(proof: expectedProof, fingerprint: fingerprint), .accepted)
        XCTAssertEqual(store.redeem(proof: expectedProof, fingerprint: fingerprint), .noCode)
    }
    func testWrongFingerprintFails() {
        let store = PairingCodeStore(generator: { "482913" })
        _ = store.issue()
        XCTAssertEqual(store.redeem(proof: expectedProof, fingerprint: String(repeating: "cd", count: 32)), .wrongCode(attemptsLeft: 4))
    }
    func testFiveFailuresInvalidate() {
        let store = PairingCodeStore(generator: { "482913" })
        _ = store.issue()
        for left in [4, 3, 2, 1, 0] {
            XCTAssertEqual(store.redeem(proof: "00", fingerprint: fingerprint), .wrongCode(attemptsLeft: left))
        }
        XCTAssertEqual(store.redeem(proof: expectedProof, fingerprint: fingerprint), .noCode)
    }
    func testExpiry() {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = PairingCodeStore(now: { now }, generator: { "482913" })
        _ = store.issue()
        now = now.addingTimeInterval(601)
        XCTAssertEqual(store.redeem(proof: expectedProof, fingerprint: fingerprint), .expired)
    }
    func testRateLimiter() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = RateLimiter(limit: 3, per: 60, now: { now })
        XCTAssertTrue(limiter.allow("a")); XCTAssertTrue(limiter.allow("a")); XCTAssertTrue(limiter.allow("a"))
        XCTAssertFalse(limiter.allow("a"))
        XCTAssertTrue(limiter.allow("b"))
        now = now.addingTimeInterval(61)
        XCTAssertTrue(limiter.allow("a"))
    }
}
