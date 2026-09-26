import XCTest
@testable import IrisBridgeCore

/// What `iris-bridge status` prints, from the helper's own `/status` reply.
final class StatusReportTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!

    func testStatusPrintsSignInVersionUsageAndAddresses() {
        let status: [String: Any] = [
            "helperVersion": "0.2.5", "hostName": "Studio Mac",
            "providers": ["claude": ["ready": false, "message": "Sign in with your Claude or ChatGPT account on the Mac, then check again."],
                          "codex": ["ready": true, "message": "Signed in with ChatGPT. Your plan limits apply."]],
            "health": ["claude": ["installed": true, "signedIn": false, "account": "", "cliVersion": "2.1.274", "usage": "unknown",
                                  "lastErrorCause": "signedOut"],
                       "codex": ["installed": true, "signedIn": true, "account": "", "cliVersion": "0.155.0-alpha.9.2", "usage": "limited",
                                 "resetsAt": "2026-09-26T12:41:00Z", "lastErrorCause": "usageLimit"]],
        ]
        let lines = StatusReport.lines(status: status, port: 48731, pairedDevices: 2, addresses: ["Studio-Mac.local", "192.168.1.23"],
                                       now: Date(timeIntervalSince1970: 1_790_133_024), timeZone: newYork)
        XCTAssertEqual(lines, [
            "Iris Bridge 0.2.5 on Studio Mac (port 48731)",
            "  claude: not signed in — Sign in with your Claude or ChatGPT account on the Mac, then check again. — CLI 2.1.274 — last turn failed: signedOut",
            "  codex: signed in — Signed in with ChatGPT. Your plan limits apply. — CLI 0.155.0-alpha.9.2 — usage limit until Sep 26, 8:41 AM",
            "  paired devices: 2",
            "  reach this Mac at: Studio-Mac.local, 192.168.1.23",
        ])
    }

    func testAnOlderHelperWithoutHealthStillPrints() {
        let lines = StatusReport.lines(status: ["helperVersion": "0.2.4", "hostName": "Studio Mac",
                                                "providers": ["claude": ["ready": true, "message": "Signed in."]]],
                                       port: 48731, pairedDevices: 0, addresses: [])
        XCTAssertEqual(lines, ["Iris Bridge 0.2.4 on Studio Mac (port 48731)", "  claude: signed in — Signed in.",
                               "  codex: not signed in — ", "  paired devices: 0"])
    }

    func testASignInTheMacCouldNotCheckIsNotPrintedAsSignedOut() {
        let sentence = "Couldn't check Claude's sign-in just now — the Mac may be busy. Trying anyway."
        let lines = StatusReport.lines(status: ["helperVersion": "0.3.0", "hostName": "Studio Mac",
                                                "providers": ["claude": ["ready": true, "message": sentence],
                                                              "codex": ["ready": true, "message": "Signed in with ChatGPT. Your plan limits apply."]],
                                                "health": ["claude": ["installed": true, "signedIn": true, "account": "", "cliVersion": "2.1.274",
                                                                      "usage": "unknown", "signInChecked": false],
                                                           "codex": ["installed": true, "signedIn": true, "account": "", "cliVersion": "0.155.0",
                                                                     "usage": "unknown"]]],
                                       port: 48731, pairedDevices: 1, addresses: [])
        XCTAssertEqual(lines[1], "  claude: sign-in unknown — \(sentence) — CLI 2.1.274")
        XCTAssertEqual(lines[2], "  codex: signed in — Signed in with ChatGPT. Your plan limits apply. — CLI 0.155.0")
    }

    func testLANAddressesLeaveOutLoopbackAndLinkLocal() {
        for address in HostName.lanAddresses() {
            XCTAssertFalse(address.hasPrefix("127.") || address.hasPrefix("169.254."), address)
            XCTAssertEqual(address.split(separator: ".").count, 4, address)
        }
    }
}
