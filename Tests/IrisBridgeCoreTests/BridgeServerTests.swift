import XCTest
import Network
@testable import IrisBridgeCore

final class BridgeServerTests: XCTestCase {
    /// Loopback is what separates an `/admin/*` caller from the rest of the network, and what a connection is
    /// counted against in the connection budget, so every shape the endpoint can take is pinned here.
    func testContextClassifiesLoopback() {
        let cases: [(host: String, address: String, loopback: Bool)] = [
            ("127.0.0.1", "127.0.0.1", true),
            ("::1", "::1", true),
            ("::ffff:127.0.0.1", "::ffff:127.0.0.1", true),
            ("fe80::1%en0", "fe80::1", false),
            ("192.168.1.20", "192.168.1.20", false),
            ("10.0.0.5", "10.0.0.5", false),
            ("some-name.local", "some-name.local", false),
        ]
        for c in cases {
            let context = BridgeServer.classify(hostDescription: c.host)
            XCTAssertEqual(context.isLoopback, c.loopback, "loopback for \(c.host)")
            XCTAssertEqual(context.sourceAddress, c.address, "address for \(c.host)")
        }
    }

    /// A phone that locks or changes network mid-request drops its connection. That is ordinary, and it was
    /// 87 of the 91 ERROR lines in a week of bridge.log (I3), so it is logged at INFO. Anything else stays ERROR.
    func testPeerDropsAreRecognisedAndRealFailuresAreNot() {
        for code: POSIXErrorCode in [.ECONNRESET, .ENOTCONN, .ECONNREFUSED, .ECONNABORTED, .ECANCELED, .EPIPE, .ETIMEDOUT] {
            XCTAssertTrue(BridgeServer.isPeerDrop(.posix(code)), "\(code)")
        }
        XCTAssertTrue(BridgeServer.isPeerDrop(.tls(-9816)), "server closed session with no notification")
        XCTAssertTrue(BridgeServer.isPeerDrop(.tls(-9806)), "connection closed via error")
        XCTAssertTrue(BridgeServer.isPeerDrop(.tls(-9805)), "connection closed gracefully")
        XCTAssertFalse(BridgeServer.isPeerDrop(.posix(.ENOMEM)))
        XCTAssertFalse(BridgeServer.isPeerDrop(.tls(-9808)), "a bad certificate is a real failure")
    }
}
