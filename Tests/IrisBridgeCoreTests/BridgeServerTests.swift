import XCTest
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
}
