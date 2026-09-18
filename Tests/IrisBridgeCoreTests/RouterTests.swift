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
    var inbox: InboxStore!; var context: ContextStore!
    let fingerprint = String(repeating: "ab", count: 32)
    var token = ""
    override func setUp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        devices = DeviceStore(file: dir.appendingPathComponent("devices.json"))
        pairing = PairingCodeStore(generator: { "482913" })
        generator = FakeGenerator()
        inbox = InboxStore(file: dir.appendingPathComponent("inbox.json"))
        context = ContextStore(file: dir.appendingPathComponent("context.json"))
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: generator, log: nil)
        token = try! devices.issue(name: "Phone", platform: "iphone").token
    }
    private func raw(_ method: String, _ path: String, body: String? = nil, auth: String? = nil, origin: String? = nil, loopback: Bool = false) -> (Int, Data) {
        var headers: [String: String] = [:]
        if let auth { headers["authorization"] = "Bearer " + auth }
        if let origin { headers["origin"] = origin }
        let request = HTTPRequest(method: method, path: path, headers: headers, body: Data((body ?? "").utf8))
        let response = router.handle(request, context: RequestContext(sourceAddress: loopback ? "127.0.0.1" : "192.168.1.20", isLoopback: loopback))
        return (response.status, response.body)
    }
    private func send(_ method: String, _ path: String, body: String? = nil, auth: String? = nil, origin: String? = nil, loopback: Bool = false) -> (Int, [String: Any]) {
        let (status, data) = raw(method, path, body: body, auth: auth, origin: origin, loopback: loopback)
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
    private func sendList(_ method: String, _ path: String, body: String? = nil, auth: String? = nil, loopback: Bool = false) -> (Int, [[String: Any]]) {
        let (status, data) = raw(method, path, body: body, auth: auth, loopback: loopback)
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? [])
    }
    private let postBody = #"{"title":"Three shots","pillar":"Craft","platform":"Instagram","format":"Reel"}"#
    @discardableResult
    private func submit(title: String = "Three shots") -> Submission {
        try! inbox.submit(kind: .post,
                          post: SubmittedPost(title: title, pillar: "Craft", platform: "Instagram", format: "Reel"),
                          series: nil, agent: "claude", note: "Ready for you.", revisionOf: nil)
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

    // MARK: - Inbox

    func testInboxNeedsADeviceTokenAndListsPending() {
        submit()
        XCTAssertEqual(send("GET", "/inbox").0, 401)
        XCTAssertEqual(send("GET", "/inbox", auth: "admin-secret", loopback: true).0, 401)
        let (status, body) = send("GET", "/inbox", auth: token)
        XCTAssertEqual(status, 200)
        let submissions = body["submissions"] as? [[String: Any]]
        XCTAssertEqual(submissions?.count, 1)
        XCTAssertEqual(submissions?.first?["kind"] as? String, "post")
        XCTAssertEqual(submissions?.first?["status"] as? String, "pending")
        XCTAssertEqual(submissions?.first?["agent"] as? String, "claude")
        XCTAssertEqual((submissions?.first?["post"] as? [String: Any])?["title"] as? String, "Three shots")
        // Dates travel as ISO 8601 strings, and the reply carries the helper's clock so the app can page with `since`.
        XCTAssertNotNil(ISO8601DateFormatter().date(from: (body["now"] as? String) ?? ""))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: (submissions?.first?["createdAt"] as? String) ?? ""))
    }

    func testInboxSinceIsParsedAndAMalformedSinceIsIgnored() {
        let old = submit(title: "Old one")
        _ = try! inbox.decide(id: old.id, status: .approved, comment: nil)
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let filtered = send("GET", "/inbox?since=" + future, auth: token)
        XCTAssertEqual((filtered.1["submissions"] as? [[String: Any]])?.count, 0)
        // A `since` we cannot read is treated as no `since` at all rather than an error.
        let garbage = send("GET", "/inbox?since=not-a-date", auth: token)
        XCTAssertEqual(garbage.0, 200)
        XCTAssertEqual((garbage.1["submissions"] as? [[String: Any]])?.count, 1)
    }

    func testDecisionApprovesOnceThenConflicts() {
        let submission = submit()
        let (status, body) = send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"approved"}"#, auth: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["status"] as? String, "approved")
        XCTAssertNotNil(body["decidedAt"])
        XCTAssertEqual(inbox.pending.count, 0)
        let again = send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"denied"}"#, auth: token)
        XCTAssertEqual(again.0, 409)
        XCTAssertEqual(again.1["error"] as? String, "Already decided.")
    }

    func testDecisionRejectsUnknownIDsBadStatusAndNoToken() {
        let submission = submit()
        XCTAssertEqual(send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"approved"}"#).0, 401)
        let unknown = send("POST", "/inbox/sub_zzzzzzzzzzzz/decision", body: #"{"status":"approved"}"#, auth: token)
        XCTAssertEqual(unknown.0, 404)
        XCTAssertEqual(unknown.1["error"] as? String, "Not found.")
        XCTAssertEqual(send("POST", "/inbox/not-an-id/decision", body: #"{"status":"approved"}"#, auth: token).0, 404)
        XCTAssertEqual(send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"maybe"}"#, auth: token).0, 400)
        XCTAssertEqual(send("POST", "/inbox/\(submission.id)/decision", body: "{}", auth: token).0, 400)
    }

    func testDecisionKeepsTheComment() {
        let submission = submit()
        let long = String(repeating: "x", count: 2_500)
        let body = try! JSONSerialization.data(withJSONObject: ["status": "changesRequested", "comment": "  " + long + "  "])
        let (status, reply) = send("POST", "/inbox/\(submission.id)/decision", body: String(data: body, encoding: .utf8), auth: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(reply["status"] as? String, "changesRequested")
        XCTAssertEqual((reply["comment"] as? String)?.count, 2_000)
    }

    /// A decision the store cannot write is a server error, not a missing submission: the row has already
    /// changed in memory, and telling the app "Not found." would send it looking for a submission that is there.
    func testDecisionReportsASaveFailureAsAServerError() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doomed = InboxStore(file: dir.appendingPathComponent("inbox.json"))
        let submission = try! doomed.submit(kind: .post,
                                            post: SubmittedPost(title: "Three shots", pillar: "Craft", platform: "Instagram", format: "Reel"),
                                            series: nil, agent: "claude", note: nil, revisionOf: nil)
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: doomed, context: context, generator: generator, log: nil)
        // The file the store writes through is gone, so `save()` throws where the decision itself would have worked.
        try! FileManager.default.removeItem(at: dir)

        let (status, body) = send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"approved"}"#, auth: token)
        XCTAssertEqual(status, 500)
        XCTAssertEqual(body["error"] as? String, "Iris Bridge could not save that decision. Try again.")
    }

    // MARK: - Context

    /// A Mac nobody has paired with is the state every new install is in, and "open Iris on a paired device"
    /// tells an agent nothing it can pass on. It is told what the person has to do instead.
    func testContextOnAnUnpairedMacSaysHowToPair() throws {
        for device in devices.all { _ = try devices.revoke(id: device.id) }
        let missing = send("GET", "/admin/context", auth: "admin-secret", loopback: true)
        XCTAssertEqual(missing.0, 404)
        XCTAssertEqual(missing.1["error"] as? String, Router.notPairedSentence)
    }

    func testContextRoundTripsFromDeviceToAdmin() {
        let missing = send("GET", "/admin/context", auth: "admin-secret", loopback: true)
        XCTAssertEqual(missing.0, 404)
        XCTAssertEqual(missing.1["error"] as? String, "No workspace context yet. Open Iris on a paired device.")

        let payload = #"{"creatorName":"Chey","pillars":[{"name":"Craft","detail":"How it is made","isAnchor":true,"weekdays":[2]}],"platforms":[{"name":"Instagram","formats":["Reel"],"weeklyGoal":3}],"series":[],"updatedAt":"2026-09-16T10:00:00Z"}"#
        XCTAssertEqual(send("PUT", "/context", body: payload).0, 401)
        let saved = send("PUT", "/context", body: payload, auth: token)
        XCTAssertEqual(saved.0, 200)
        XCTAssertEqual(saved.1["saved"] as? Bool, true)
        XCTAssertEqual(context.current?.creatorName, "Chey")

        let read = send("GET", "/admin/context", auth: "admin-secret", loopback: true)
        XCTAssertEqual(read.0, 200)
        XCTAssertEqual(read.1["creatorName"] as? String, "Chey")
        XCTAssertEqual((read.1["pillars"] as? [[String: Any]])?.first?["name"] as? String, "Craft")
    }

    func testContextRejectsUnreadableAndOversizedBodies() {
        XCTAssertEqual(send("PUT", "/context", body: "{}", auth: token).0, 400)
        XCTAssertEqual(send("PUT", "/context", body: "not json", auth: token).0, 400)
        let filler = String(repeating: "a", count: 260 * 1024)
        let big = #"{"creatorName":"\#(filler)","pillars":[],"platforms":[],"series":[],"updatedAt":"2026-09-16T10:00:00Z"}"#
        XCTAssertEqual(send("PUT", "/context", body: big, auth: token).0, 413)
    }

    /// The app writes `updatedAt` with fractional seconds. Plain `.iso8601` decoding refuses those, so the
    /// snapshot is read with the same tolerance `since` gets.
    func testContextAcceptsFractionalSecondTimestamps() {
        let payload = #"{"creatorName":"Chey","pillars":[],"platforms":[],"series":[],"updatedAt":"2026-09-16T20:00:00.123Z"}"#
        let (status, body) = send("PUT", "/context", body: payload, auth: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["saved"] as? Bool, true)
        XCTAssertEqual(context.current?.updatedAt.timeIntervalSince1970 ?? 0, 1789588800.123, accuracy: 0.002)
    }

    // MARK: - Admin inbox

    func testAdminSubmitNeedsLoopbackAndAdminTokenThenValidates() {
        let body = #"{"kind":"post","agent":"claude","note":"Ready for you.","post":\#(postBody)}"#
        XCTAssertEqual(send("POST", "/admin/inbox", body: body, auth: "admin-secret", loopback: false).0, 404)
        XCTAssertEqual(send("POST", "/admin/inbox", body: body, auth: "wrong", loopback: true).0, 401)
        let (status, reply) = send("POST", "/admin/inbox", body: body, auth: "admin-secret", loopback: true)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(reply["kind"] as? String, "post")
        XCTAssertEqual(reply["agent"] as? String, "claude")
        XCTAssertEqual(reply["note"] as? String, "Ready for you.")
        XCTAssertEqual(reply["status"] as? String, "pending")
        XCTAssertTrue((reply["id"] as? String)?.hasPrefix("sub_") == true)
        XCTAssertEqual(inbox.pending.count, 1)

        // Validation failures come back as 400 with the sentence the creator's agent should read.
        let empty = send("POST", "/admin/inbox", body: #"{"kind":"post","agent":"claude"}"#, auth: "admin-secret", loopback: true)
        XCTAssertEqual(empty.0, 400)
        XCTAssertEqual(empty.1["error"] as? String, "Add a post to submit.")
        let noTitle = #"{"kind":"post","agent":"claude","post":{"title":"  ","pillar":"Craft","platform":"Instagram","format":"Reel"}}"#
        XCTAssertEqual(send("POST", "/admin/inbox", body: noTitle, auth: "admin-secret", loopback: true).1["error"] as? String, "Give the post a title.")
        XCTAssertEqual(send("POST", "/admin/inbox", body: "{}", auth: "admin-secret", loopback: true).0, 400)
    }

    func testAdminInboxListsPendingByDefaultAndAllOnRequest() {
        let first = submit(title: "First")
        submit(title: "Second")
        _ = try! inbox.decide(id: first.id, status: .denied, comment: "Not this week.")
        let pending = sendList("GET", "/admin/inbox", auth: "admin-secret", loopback: true)
        XCTAssertEqual(pending.0, 200)
        XCTAssertEqual(pending.1.count, 1)
        XCTAssertEqual((pending.1.first?["post"] as? [String: Any])?["title"] as? String, "Second")
        XCTAssertEqual(sendList("GET", "/admin/inbox?status=pending", auth: "admin-secret", loopback: true).1.count, 1)
        let all = sendList("GET", "/admin/inbox?status=all", auth: "admin-secret", loopback: true)
        XCTAssertEqual(all.1.count, 2)
        XCTAssertEqual(send("GET", "/admin/inbox", auth: token, loopback: false).0, 404)
    }

    /// `iris-bridge inbox clear-decided`. Pending work is never old enough to go, however long it has been
    /// sitting there: nobody has looked at it yet.
    func testAdminInboxPruneDropsDecidedSubmissionsOlderThanThirtyDays() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        inbox = InboxStore(file: dir.appendingPathComponent("inbox.json"), now: { clock })
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: generator, log: nil)
        let decided = submit(title: "Long ago")
        _ = try! inbox.decide(id: decided.id, status: .approved, comment: nil)
        let stillWaiting = submit(title: "Never looked at")
        clock = clock.addingTimeInterval(31 * 24 * 60 * 60)
        let recent = submit(title: "Yesterday")
        _ = try! inbox.decide(id: recent.id, status: .denied, comment: "Not this week.")

        XCTAssertEqual(send("POST", "/admin/inbox/prune", auth: "admin-secret", loopback: false).0, 404)
        XCTAssertEqual(send("POST", "/admin/inbox/prune", auth: "wrong", loopback: true).0, 401)
        let (status, body) = send("POST", "/admin/inbox/prune", auth: "admin-secret", loopback: true)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["removed"] as? Int, 1)
        XCTAssertEqual(inbox.all(since: Date(timeIntervalSince1970: 0)).map(\.id).sorted(), [recent.id, stillWaiting.id].sorted())
    }
}
