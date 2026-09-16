import XCTest
@testable import IrisBridgeCore

private final class FakeGenerator: Generator {
    var reply: [String: Any] = ["reply": "Consider three scenes.", "proposal": NSNull(), "provider": "codex"]
    var error: BridgeError?
    var calls = 0
    var canceled: [String] = []
    func generate(_ request: MessageRequest) throws -> [String: Any] { calls += 1; if let error { throw error }; return reply }
    func status(_ provider: String) -> ProviderStatus {
        provider == "codex"
            ? ProviderStatus(provider: provider, ready: true, message: "Signed in with ChatGPT Pro. Your plan limits apply.",
                             auth: "subscription", account: "chey@example.com", model: "codex-stub")
            : ProviderStatus(provider: provider, ready: false, message: "Install Claude Code on your Mac first.")
    }
    func cancel(_ id: String) { canceled.append(id) }
}

final class RouterTests: XCTestCase {
    var router: Router!; var devices: DeviceStore!; var pairing: PairingCodeStore!; fileprivate var generator: FakeGenerator!
    let fingerprint = String(repeating: "ab", count: 32)
    var token = ""
    override func setUp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        devices = DeviceStore(file: dir.appendingPathComponent("devices.json"))
        pairing = PairingCodeStore(generator: { "482913" })
        generator = FakeGenerator()
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing, generator: generator, log: nil)
        token = try! devices.issue(name: "Phone", platform: "iphone").token
    }
    private func send(_ method: String, _ path: String, body: String? = nil, auth: String? = nil, origin: String? = nil, loopback: Bool = false) -> (Int, [String: Any]) {
        var headers: [String: String] = [:]
        if let auth { headers["authorization"] = "Bearer " + auth }
        if let origin { headers["origin"] = origin }
        let request = HTTPRequest(method: method, path: path, headers: headers, body: Data((body ?? "").utf8))
        let response = router.handle(request, context: RequestContext(sourceAddress: loopback ? "127.0.0.1" : "192.168.1.20", isLoopback: loopback))
        return (response.status, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:])
    }
    func testStatusIsPublicAndReportsProviders() {
        let (status, body) = send("GET", "/status")
        XCTAssertEqual(status, 200); XCTAssertEqual(body["version"] as? Int, 2); XCTAssertEqual(body["hostName"] as? String, "Studio Mac")
        XCTAssertEqual(body["helperVersion"] as? String, BridgeVersion.current)
        let providers = body["providers"] as? [String: Any]
        let codex = providers?["codex"] as? [String: Any]
        XCTAssertEqual(codex?["ready"] as? Bool, true)
        XCTAssertEqual(codex?["model"] as? String, "codex-stub")
        // Readiness and the model are public; who is signed in and on what plan are not.
        XCTAssertEqual(codex?["message"] as? String, "Signed in.")
        XCTAssertNil(codex?["account"]); XCTAssertNil(codex?["auth"])
        let claude = providers?["claude"] as? [String: Any]
        XCTAssertEqual(claude?["ready"] as? Bool, false)
        XCTAssertEqual(claude?["message"] as? String, "Install Claude Code on your Mac first.")
    }
    func testStatusHidesAccountUntilAuthenticated() {
        func codexEntry(_ body: [String: Any]) -> [String: Any] {
            ((body["providers"] as? [String: Any])?["codex"] as? [String: Any]) ?? [:]
        }
        let anonymous = codexEntry(send("GET", "/status").1)
        XCTAssertNil(anonymous["account"]); XCTAssertNil(anonymous["auth"])
        XCTAssertEqual(anonymous["message"] as? String, "Signed in.")
        // A bearer that matches nothing is treated as no bearer at all, not as a reason to refuse /status.
        let wrongToken = codexEntry(send("GET", "/status", auth: "not-a-token").1)
        XCTAssertNil(wrongToken["account"])
        // The admin token is only the admin token when it arrives from this Mac.
        XCTAssertNil(codexEntry(send("GET", "/status", auth: "admin-secret", loopback: false).1)["account"])

        let paired = send("GET", "/status", auth: token)
        XCTAssertEqual(paired.0, 200)
        XCTAssertEqual(codexEntry(paired.1)["account"] as? String, "chey@example.com")
        XCTAssertEqual(codexEntry(paired.1)["auth"] as? String, "subscription")
        XCTAssertEqual(codexEntry(paired.1)["message"] as? String, "Signed in with ChatGPT Pro. Your plan limits apply.")
        // `iris-bridge status` reaches the same detail over loopback with the admin token.
        XCTAssertEqual(codexEntry(send("GET", "/status", auth: "admin-secret", loopback: true).1)["account"] as? String, "chey@example.com")
    }
    func testOriginHeaderIsRejectedEverywhere() {
        XCTAssertEqual(send("GET", "/status", origin: "https://example.org").0, 403)
        XCTAssertEqual(send("POST", "/message", body: "{}", auth: token, origin: "https://example.org").0, 403)
        XCTAssertEqual(generator.calls, 0)
    }
    func testMessageRequiresDeviceToken() {
        XCTAssertEqual(send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#).0, 401)
        let (status, body) = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: "wrong")
        XCTAssertEqual(status, 401); XCTAssertEqual(body["error"] as? String, "device-revoked")
        XCTAssertEqual(generator.calls, 0)
    }
    func testPairIssuesTokenAndInvalidatesCode() {
        _ = pairing.issue()
        let proof = PairingProof.compute(code: "482913", fingerprint: fingerprint)
        let (status, body) = send("POST", "/pair", body: #"{"deviceName":"Chey's iPhone","platform":"iphone","proof":"\#(proof)"}"#)
        XCTAssertEqual(status, 200)
        let newToken = body["token"] as! String
        XCTAssertEqual(body["hostName"] as? String, "Studio Mac"); XCTAssertNotNil(body["deviceID"])
        XCTAssertEqual(send("GET", "/status", auth: newToken).0, 200)
        XCTAssertEqual(send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: newToken).0, 200)
        let again = send("POST", "/pair", body: #"{"deviceName":"Other","platform":"iphone","proof":"\#(proof)"}"#)
        XCTAssertEqual(again.0, 400); XCTAssertEqual(again.1["error"] as? String, "no-code")
    }
    func testWrongProofReportsAttempts() {
        _ = pairing.issue()
        let (status, body) = send("POST", "/pair", body: #"{"deviceName":"P","platform":"iphone","proof":"00"}"#)
        XCTAssertEqual(status, 400); XCTAssertEqual(body["error"] as? String, "wrong-code"); XCTAssertEqual(body["attemptsLeft"] as? Int, 4)
    }
    func testPairIsRateLimitedPerAddress() {
        for _ in 0..<10 { _ = send("POST", "/pair", body: #"{"deviceName":"P","platform":"iphone","proof":"00"}"#) }
        XCTAssertEqual(send("POST", "/pair", body: #"{"deviceName":"P","platform":"iphone","proof":"00"}"#).0, 429)
    }
    func testInvalidMessageIsRejectedBeforeGenerate() {
        XCTAssertEqual(send("POST", "/message", body: #"{"provider":"anything","message":"x"}"#, auth: token).0, 400)
        XCTAssertEqual(generator.calls, 0)
    }
    func testErrorsAreExplicitAndNoSampleFallback() {
        generator.error = .message("Sign in first.")
        let (status, body) = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token)
        XCTAssertEqual(status, 502); XCTAssertEqual(body["error"] as? String, "Sign in first.")
        generator.error = .timeout
        XCTAssertEqual(send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token).0, 504)
    }
    func testRetryReturnsCachedReplyWithoutRegenerating() {
        let body = #"{"id":"retry-1","provider":"codex","message":"x"}"#
        XCTAssertEqual(send("POST", "/message", body: body, auth: token).1["reply"] as? String, "Consider three scenes.")
        XCTAssertEqual(send("POST", "/message", body: body, auth: token).1["reply"] as? String, "Consider three scenes.")
        XCTAssertEqual(generator.calls, 1)
    }
    func testOnlyOneRequestAtATime() {
        router.busy = true
        XCTAssertEqual(send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token).0, 409)
        router.busy = false
    }
    func testCancelForwardsToGenerator() {
        XCTAssertEqual(send("POST", "/cancel", body: #"{"id":"abc"}"#, auth: token).0, 200)
        XCTAssertEqual(generator.canceled, ["abc"])
    }
    func testDeviceCanRemoveItself() {
        XCTAssertEqual(send("DELETE", "/device", auth: token).0, 200)
        XCTAssertEqual(send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token).0, 401)
    }
    func testAdminEndpointsRequireLoopbackAndAdminToken() {
        XCTAssertEqual(send("POST", "/admin/pair-code", auth: "admin-secret", loopback: false).0, 404)
        XCTAssertEqual(send("POST", "/admin/pair-code", auth: "wrong", loopback: true).0, 401)
        let (status, body) = send("POST", "/admin/pair-code", auth: "admin-secret", loopback: true)
        XCTAssertEqual(status, 200); XCTAssertEqual(body["code"] as? String, "482913"); XCTAssertNotNil(body["expiresAt"])
        let list = send("GET", "/admin/devices", auth: "admin-secret", loopback: true)
        XCTAssertEqual((list.1["devices"] as? [[String: Any]])?.count, 1)
        let id = (list.1["devices"] as! [[String: Any]])[0]["id"] as! String
        XCTAssertEqual(send("DELETE", "/admin/devices/" + id, auth: "admin-secret", loopback: true).0, 200)
        XCTAssertEqual(send("DELETE", "/admin/devices/" + id, auth: "admin-secret", loopback: true).0, 404)
    }
    func testUnknownPathIs404() {
        XCTAssertEqual(send("GET", "/nope", auth: token).0, 404)
    }
}
