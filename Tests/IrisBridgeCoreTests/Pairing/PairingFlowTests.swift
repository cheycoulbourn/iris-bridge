import XCTest
import CoreImage
import Vision
@testable import IrisBridgeCore

final class PairingFlowTests: XCTestCase {
    private var root: URL!
    private var devices: DeviceStore!
    private var manual: PairingCodeStore!
    private var clock = Date(timeIntervalSince1970: 10_000)
    private let fingerprint = String(repeating: "ab", count: 32)
    private let admin = String(repeating: "a", count: 40)
    private var router: Router!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        devices = DeviceStore(file: root.appendingPathComponent("devices.json"))
        manual = PairingCodeStore(now: { self.clock }, generator: { "482913" })
        configure { false }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func configure(approval: @escaping () -> Bool) {
        router = Router(fingerprint: fingerprint, hostName: "Test Mac", adminToken: admin, devices: devices, pairing: manual,
                        inbox: InboxStore(file: root.appendingPathComponent("inbox.json")), context: ContextStore(file: root.appendingPathComponent("context.json")),
                        generator: IdleGenerator(), log: nil, now: { self.clock }, pairingURL: "https://test-mac.local:48797", localApproval: { _ in approval() })
    }
    private func send(_ route: String, body: [String: Any] = [:], loopback: Bool = true,
                      contentType: String? = "application/json", origin: String? = nil, adminAuth: Bool = false) -> HTTPResponse {
        var headers: [String: String] = [:]
        headers["content-type"] = contentType; headers["origin"] = origin
        if adminAuth { headers["authorization"] = "Bearer " + admin }
        return router.handle(HTTPRequest(method: "POST", path: route, headers: headers, body: try! JSONSerialization.data(withJSONObject: body)),
                             context: RequestContext(sourceAddress: loopback ? "127.0.0.1" : "192.168.1.20", isLoopback: loopback))
    }
    private var localBody: [String: Any] { ["deviceName": "Iris Mac", "platform": "mac", "confirmation": "0123456789abcdef0123456789abcdef"] }
    private func payload() throws -> PairingQRPayload {
        let response = send("/admin/pair-qr", adminAuth: true)
        XCTAssertEqual(response.status, 200)
        return try JSONDecoder().decode(PairingQRPayload.self, from: response.body)
    }
    private func qrBody(_ qr: PairingQRPayload, fingerprint: String? = nil) -> [String: Any] {
        ["deviceName": "iPhone", "platform": "iphone", "proof": PairingProof.compute(code: qr.secret, fingerprint: fingerprint ?? qr.fingerprint)]
    }
    private func error(_ response: HTTPResponse) -> String? {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? String
    }

    func testLocalRouteRejectsRemoteBrowserWrongContentTypeAndPlatformBeforePrompting() {
        var prompts = 0; configure { prompts += 1; return true }
        XCTAssertEqual(send("/pair/local", body: localBody, loopback: false).status, 403)
        XCTAssertEqual(send("/pair/local", body: localBody, origin: "https://example.org").status, 403)
        XCTAssertEqual(send("/pair/local", body: localBody, contentType: nil).status, 415)
        XCTAssertEqual(send("/pair/local", body: localBody, contentType: "text/plain").status, 415)
        XCTAssertEqual(send("/pair/local", body: ["deviceName": "Phone", "platform": "iphone"]).status, 400)
        XCTAssertEqual(send("/pair/local", body: ["platform": "mac"]).status, 400)
        for confirmation in ["", "0123456789abcdef", String(repeating: "g", count: 32), String(repeating: "0", count: 31), String(repeating: "0", count: 33)] {
            var body = localBody; body["confirmation"] = confirmation
            XCTAssertEqual(send("/pair/local", body: body).status, 400)
        }
        var missing = localBody; missing["confirmation"] = nil
        XCTAssertEqual(send("/pair/local", body: missing).status, 400)
        XCTAssertEqual(prompts, 0); XCTAssertTrue(devices.all.isEmpty)
    }
    func testLocalDenialIssuesNoDeviceAndCooldownAndRateGuardBoundPrompts() {
        var prompts = 0; configure { prompts += 1; return false }
        for _ in 0..<3 {
            let denied = send("/pair/local", body: localBody)
            XCTAssertEqual(denied.status, 403); XCTAssertEqual(error(denied), "local-pairing-declined")
            XCTAssertEqual(send("/pair/local", body: localBody).status, 429)
            clock.addTimeInterval(11)
        }
        XCTAssertEqual(send("/pair/local", body: localBody).status, 429)
        XCTAssertEqual(prompts, 3); XCTAssertTrue(devices.all.isEmpty)
        clock.addTimeInterval(60)
        XCTAssertEqual(send("/pair/local", body: localBody).status, 403)
    }
    private func localCompletionBody() throws -> [String: Any] {
        let approved = send("/pair/local", body: localBody)
        XCTAssertEqual(approved.status, 200); XCTAssertTrue(devices.all.isEmpty)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: approved.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["approvalToken", "expiresAt"])
        XCTAssertEqual(ISO8601DateFormatter().date(from: try XCTUnwrap(body["expiresAt"] as? String)), clock.addingTimeInterval(60))
        return ["approvalToken": try XCTUnwrap(body["approvalToken"] as? String), "confirmation": localBody["confirmation"]!]
    }
    func testLocalApprovalPersistsOnlyAfterCompletionAndTokenIsOneUse() throws {
        configure { true }
        let completion = try localCompletionBody()
        XCTAssertEqual(send("/pair/local/complete", body: completion, loopback: false).status, 403)
        XCTAssertEqual(send("/pair/local/complete", body: completion, origin: "https://example.org").status, 403)
        XCTAssertEqual(send("/pair/local/complete", body: completion, contentType: nil).status, 415)
        var bad = completion; bad["approvalToken"] = "wrong"
        XCTAssertEqual(error(send("/pair/local/complete", body: bad)), "local-approval-invalid")
        bad = completion; bad["confirmation"] = String(repeating: "f", count: 32)
        XCTAssertEqual(error(send("/pair/local/complete", body: bad)), "local-approval-invalid")
        XCTAssertTrue(devices.all.isEmpty)
        let response = send("/pair/local/complete", body: completion, contentType: "application/json; charset=utf-8")
        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["deviceID", "token", "hostName"])
        let token = try XCTUnwrap(body["token"] as? String)
        XCTAssertEqual(devices.authenticate(token: token)?.platform, "mac")
        XCTAssertEqual(devices.all.count, 1)
        XCTAssertEqual(error(send("/pair/local/complete", body: completion)), "local-approval-expired")
        XCTAssertEqual(devices.all.count, 1)
    }
    func testAbandonedApprovalExpiresWithoutCreatingDevice() throws {
        configure { true }
        let completion = try localCompletionBody()
        clock.addTimeInterval(60)
        XCTAssertEqual(error(send("/pair/local/complete", body: completion)), "local-approval-expired")
        XCTAssertTrue(devices.all.isEmpty)
    }
    func testConcurrentLocalRequestsOpenOnlyOnePrompt() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        configure { entered.signal(); _ = release.wait(timeout: .now() + 5); return false }
        DispatchQueue.global().async { _ = self.send("/pair/local", body: self.localBody); done.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let second = send("/pair/local", body: localBody)
        XCTAssertEqual(second.status, 409); XCTAssertEqual(error(second), "local-pairing-busy")
        release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(devices.all.isEmpty)
    }
    func testQRAdminAuthPayloadAndSingleUseProof() throws {
        XCTAssertEqual(send("/admin/pair-qr", loopback: false, adminAuth: true).status, 404)
        XCTAssertEqual(send("/admin/pair-qr").status, 401)
        let qr = try payload()
        XCTAssertEqual(qr.version, 1); XCTAssertEqual(qr.url, "https://test-mac.local:48797")
        XCTAssertEqual(qr.hostName, "Test Mac"); XCTAssertEqual(qr.fingerprint, fingerprint)
        XCTAssertEqual(qr.secret.count, 64); XCTAssertTrue(qr.secret.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        XCTAssertEqual(ISO8601DateFormatter().date(from: qr.expiresAt), clock.addingTimeInterval(600))
        XCTAssertEqual(error(send("/pair/qr", body: qrBody(qr, fingerprint: String(repeating: "cd", count: 32)))), "qr-invalid")
        XCTAssertTrue(devices.all.isEmpty)
        XCTAssertEqual(send("/pair/qr", body: qrBody(qr), loopback: false).status, 200)
        XCTAssertEqual(devices.all.count, 1)
        XCTAssertEqual(error(send("/pair/qr", body: qrBody(qr))), "qr-expired")
        XCTAssertEqual(devices.all.count, 1)
    }
    func testIPadQRPairingUsesExistingMobileDevicePlatform() throws {
        let qr = try payload()
        var body = qrBody(qr); body["platform"] = "ipad"; body["deviceName"] = "iPad"
        XCTAssertEqual(send("/pair/qr", body: body, loopback: false).status, 200)
        XCTAssertEqual(devices.all.first?.name, "iPad")
        XCTAssertEqual(devices.all.first?.platform, "iphone", "existing store and clients group all mobile devices as iphone")
    }
    func testQRExpiryAndReplacementAndRateLimit() throws {
        let old = try payload(), newest = try payload()
        XCTAssertNotEqual(old.secret, newest.secret)
        XCTAssertEqual(error(send("/pair/qr", body: qrBody(old))), "qr-invalid")
        clock.addTimeInterval(600)
        XCTAssertEqual(error(send("/pair/qr", body: qrBody(newest))), "qr-expired")
        for _ in 0..<9 { XCTAssertEqual(send("/pair/qr", body: qrBody(newest)).status, 400) }
        XCTAssertEqual(send("/pair/qr", body: qrBody(newest)).status, 429)
        XCTAssertTrue(devices.all.isEmpty)
    }
    func testQRDoesNotInvalidateLegacyPairingCode() throws {
        let code = manual.issue().code
        _ = try payload()
        let response = send("/pair", body: ["deviceName": "Older iPhone", "platform": "iphone", "proof": PairingProof.compute(code: code, fingerprint: fingerprint)], loopback: false, contentType: nil)
        XCTAssertEqual(response.status, 200); XCTAssertEqual(devices.all.count, 1)
    }
    func testQREncodingIsVersionedBase64URLAndTerminalHasQuietZone() throws {
        let qr = try payload(), encoded = qr.encodedString
        XCTAssertTrue(encoded.hasPrefix("iris-pair:")); XCTAssertFalse(encoded.contains("/")); XCTAssertFalse(encoded.contains("="))
        var text = String(encoded.dropFirst("iris-pair:".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        XCTAssertEqual(try JSONDecoder().decode(PairingQRPayload.self, from: XCTUnwrap(Data(base64Encoded: text))), qr)
        let rendered = try TerminalPairingQR.render(qr)
        let lines = rendered.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 10)
        XCTAssertTrue(lines[0].hasPrefix("\u{001B}[30;47m    "))
        XCTAssertTrue(lines[0].hasSuffix("    \u{001B}[0m"))
        // Decode a raster reconstructed from the exact terminal glyphs, including the quiet zone.
        let cells = lines.map { Array($0.replacingOccurrences(of: "\u{001B}[30;47m", with: "").replacingOccurrences(of: "\u{001B}[0m", with: "")) }
        let width = try XCTUnwrap(cells.first?.count), height = cells.count * 2
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (row, line) in cells.enumerated() {
            XCTAssertEqual(line.count, width)
            for (column, cell) in line.enumerated() {
                if cell == "█" || cell == "▀" { pixels[(row * 2) * width + column] = 0 }
                if cell == "█" || cell == "▄" { pixels[(row * 2 + 1) * width + column] = 0 }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(ciImage: image).perform([request])
        XCTAssertEqual(request.results?.first?.payloadStringValue, encoded, "the exact terminal QR modules must scan")
        XCTAssertTrue(LocalPairingApproval.script.contains("default button \"Cancel\""))
        XCTAssertTrue(LocalPairingApproval.script.contains("giving up after 60"))
        XCTAssertFalse(LocalPairingApproval.script.contains("deviceName"))
        XCTAssertTrue(LocalPairingApproval.script.contains("item 1 of argv"))
        XCTAssertEqual(LocalPairingApproval.formatted("0123456789abcdef0123456789abcdef"), "0123 4567 89AB")
    }

    /// Real TLS listener with a temporary identity, random port and certificate pin, never the installed
    /// helper. It exercises both the CLI's admin challenge and the app's pairing proof on the wire.
    func testRealTLSQRPairingAndLegacyCLICompatibility() throws {
        let live = try LiveTestServer()
        let paths = BridgePaths(root: live.root, logs: live.root.appendingPathComponent("logs"))
        try BridgePaths.writePrivate(Data(admin.utf8), to: paths.adminToken)
        let client = try AdminClient(paths: paths, port: live.port)
        let qr = try client.pairQR()
        XCTAssertEqual(URLComponents(string: qr.url)?.port, Int(live.port))
        XCTAssertEqual(qr.fingerprint, live.fingerprint)
        let session = live.session(); defer { session.invalidateAndCancel() }
        func call(_ route: String, body: [String: Any], headers: [String: String] = [:]) throws -> HTTPResponse {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(live.port)" + route)!)
            request.httpMethod = "POST"; request.timeoutInterval = 5
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let finished = DispatchSemaphore(value: 0)
            var result: HTTPResponse?, failure: Error?
            session.dataTask(with: request) { data, response, error in
                failure = error
                result = HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data ?? Data())
                finished.signal()
            }.resume()
            XCTAssertEqual(finished.wait(timeout: .now() + 7), .success)
            if let failure { throw failure }
            return try XCTUnwrap(result)
        }
        let body: [String: Any] = ["deviceName": "QR iPad", "platform": "ipad", "proof": PairingProof.compute(code: qr.secret, fingerprint: qr.fingerprint)]
        XCTAssertEqual(try call("/pair/qr", body: body, headers: ["Origin": "https://example.org"]).status, 403)
        let paired = try call("/pair/qr", body: body)
        XCTAssertEqual(paired.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: paired.body) as? [String: Any])
        XCTAssertNotNil(live.devices.authenticate(token: try XCTUnwrap(json["token"] as? String)))
        XCTAssertEqual(error(try call("/pair/qr", body: body)), "qr-expired")
        let code = try client.pairCode().code
        XCTAssertEqual(try call("/pair", body: ["deviceName": "Legacy phone", "proof": PairingProof.compute(code: code, fingerprint: live.fingerprint)]).status, 200)
        XCTAssertEqual(live.devices.all.count, 3)
    }
}
