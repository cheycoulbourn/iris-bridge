import XCTest
@testable import IrisBridgeCore

/// `transportError` and `statusError` turn a URL-loading failure or a non-200 reply into the sentence the
/// user reads in Terminal. They are pure functions of their inputs, so they are checked here rather than by
/// standing a helper up and breaking it.
final class AdminClientErrorTests: XCTestCase {
    private func text(_ error: Error) -> String { error.localizedDescription }

    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "url error \(code)"])
    }

    func testRefusedConnectionSaysTheHelperIsNotRunning() {
        let message = text(AdminClient.transportError(urlError(NSURLErrorCannotConnectToHost)))
        XCTAssertEqual(message, "Iris Bridge is not running on this Mac. Run the install command again to start it.")
    }

    func testTimeoutAlsoSaysTheHelperIsNotRunning() {
        let message = text(AdminClient.transportError(urlError(NSURLErrorTimedOut)))
        XCTAssertTrue(message.contains("is not running on this Mac"), message)
    }

    /// The pinning delegate cancels the challenge when the fingerprint does not match, and URLSession reports
    /// that as a plain cancellation — so this code, and not a TLS-specific one, is the stale-install signal.
    func testCancelledChallengeSaysTheCertificateDoesNotMatch() {
        let message = text(AdminClient.transportError(urlError(NSURLErrorCancelled)))
        XCTAssertEqual(message, "Iris Bridge's certificate does not match. Run `iris-bridge uninstall`, then install again.")
    }

    func testUntrustedCertificateSaysTheSameThing() {
        let message = text(AdminClient.transportError(urlError(NSURLErrorServerCertificateUntrusted)))
        XCTAssertTrue(message.contains("certificate does not match"), message)
    }

    /// Anything that is not a URL error at all still has to read as a sentence, not as a raw domain/code.
    func testUnrecognisedFailureFallsBackToTheUnderlyingDescription() {
        let message = text(AdminClient.transportError(BridgeError.message("the socket melted")))
        XCTAssertEqual(message, "Could not reach Iris Bridge: the socket melted")
    }

    func testUnauthorisedNamesTheAdminToken() {
        let message = text(AdminClient.statusError(401, [:], while: "report its status"))
        XCTAssertEqual(message, "The admin token does not match the running helper. Restart Iris Bridge (run the install command again).")
        XCTAssertFalse(message.contains("401"), "a token mismatch should read as advice, not as a status code")
    }

    func testServerErrorNamesTheActionAndRepeatsWhatTheHelperSaid() {
        let message = text(AdminClient.statusError(500, ["error": "x"], while: "list paired devices"))
        XCTAssertEqual(message, "Iris Bridge could not list paired devices (HTTP 500 — x).")
    }

    func testServerErrorWithoutABodyStillNamesTheAction() {
        let message = text(AdminClient.statusError(503, [:], while: "create a pairing code"))
        XCTAssertEqual(message, "Iris Bridge could not create a pairing code (HTTP 503).")
    }
}
