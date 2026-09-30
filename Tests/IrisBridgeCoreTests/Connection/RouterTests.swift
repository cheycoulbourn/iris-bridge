import XCTest
@testable import IrisBridgeCore

private final class FakeGenerator: Generator {
    var reply: [String: Any] = ["reply": "Consider three scenes.", "proposal": NSNull(), "provider": "codex"]
    var error: Error?
    var calls = 0
    var canceled: [String] = []
    /// Replaces Claude's sign-in answer when set.
    var claudeStatus: ProviderStatus?
    /// The sign-in answers `health(_:signIn:)` was handed, so a test can see `/status` asked each provider once.
    var healthSignIns: [String: ProviderStatus] = [:]
    func generate(_ request: MessageRequest) throws -> [String: Any] { calls += 1; if let error { throw error }; return reply }
    func status(_ provider: String) -> ProviderStatus {
        if provider == "claude", let claudeStatus { return claudeStatus }
        return provider == "codex"
            ? ProviderStatus(provider: provider, ready: true, message: "Signed in with ChatGPT Pro. Your plan limits apply.",
                             auth: "subscription", account: "chey@example.com", model: "codex-stub")
            : ProviderStatus(provider: provider, ready: false, message: "Install Claude Code on your Mac first.")
    }
    func health(_ provider: String) -> ProviderHealth {
        provider == "codex"
            ? ProviderHealth(installed: true, signedIn: true, account: "Pro", cliVersion: "0.155.0-alpha.9.2", usage: .limited,
                             resetsAt: Date(timeIntervalSince1970: 1_790_426_460), lastErrorCause: .usageLimit)
            : ProviderHealth(installed: false, signedIn: false, account: "", cliVersion: "", usage: .unknown)
    }
    func health(_ provider: String, signIn: ProviderStatus) -> ProviderHealth {
        healthSignIns[provider] = signIn
        var health = health(provider)
        health.signInChecked = signIn.checked
        return health
    }
    func models(_ provider: String) -> ProviderModelCatalog {
        guard provider == "codex" else {
            return ProviderModelCatalog(provider: provider, models: [], source: "unavailable", notice: "Install Claude Code on your Mac first.")
        }
        return ProviderModelCatalog(provider: "codex", models: [ProviderModel(id: "codex-stub", name: "Codex Stub", efforts: ["low", "medium", "high"], defaultEffort: "medium")], source: "live-codex-app-server", defaultModelID: "codex-stub")
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
    /// The v2 Inbox's clock; a test that moves time sets it before its first `submit`.
    private var inboxClock: () -> Date = Date.init
    /// A submission helper 0.2.x saved: added to `inbox.json`, then the store and router are opened on it again.
    @discardableResult
    private func submit(title: String = "Three shots") -> Submission {
        let submission = SavedInbox.post(title: title, createdAt: inboxClock())
        inbox = SavedInbox.store(inbox.all(since: Date(timeIntervalSince1970: 0)).reversed() + [submission], file: inbox.file, now: inboxClock)
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: generator, log: nil)
        return submission
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
        // A bearer that matches nothing, or the admin token from off this Mac, is refused rather than answered
        // as anonymous (contract §2). `testATokenThatMatchesNothingIsRefusedAtOnce` pins the reply.
        XCTAssertEqual(send("GET", "/status", auth: "not-a-token").0, 401)
        XCTAssertEqual(send("GET", "/status", auth: "admin-secret", loopback: false).0, 401)

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
    func testModelsRequiresDeviceTokenAndReturnsTheCatalog() {
        XCTAssertEqual(send("GET", "/models?provider=codex").0, 401)
        let (status, body) = send("GET", "/models?provider=codex", auth: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["provider"] as? String, "codex")
        XCTAssertEqual(body["source"] as? String, "live-codex-app-server")
        XCTAssertEqual(body["defaultModelID"] as? String, "codex-stub")
        let model = (body["models"] as? [[String: Any]])?.first
        XCTAssertEqual(model?["id"] as? String, "codex-stub")
        XCTAssertEqual(model?["efforts"] as? [String], ["low", "medium", "high"])
    }
    func testModelsRejectsAnUnknownProvider() {
        XCTAssertEqual(send("GET", "/models", auth: token).0, 400)
        XCTAssertEqual(send("GET", "/models?provider=other", auth: token).0, 400)
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
        generator.error = BridgeError.message("Sign in first.")
        let (status, body) = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token)
        XCTAssertEqual(status, 502); XCTAssertEqual(body["error"] as? String, "Sign in first.")
        generator.error = BridgeError.timeout
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
        let submission = SavedInbox.post("sub_aaaaaaaaaaaa")
        let doomed = SavedInbox.store([submission], file: dir.appendingPathComponent("inbox.json"))
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: doomed, context: context, generator: generator, log: nil)
        // The file the store writes through is gone, so `save()` throws where the decision itself would have worked.
        try! FileManager.default.removeItem(at: dir)

        let (status, body) = send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"approved"}"#, auth: token)
        XCTAssertEqual(status, 500)
        XCTAssertEqual(body["error"] as? String, "Iris Bridge could not save that decision. Try again.")
    }

    // MARK: - Context

    /// An older app still pushes its context; the Iris read tools answer from it until a v3 app pushes a snapshot.
    func testAnOlderAppsContextIsStillSaved() {
        let payload = #"{"creatorName":"Chey","pillars":[{"name":"Craft","detail":"How it is made","isAnchor":true,"weekdays":[2]}],"platforms":[{"name":"Instagram","formats":["Reel"],"weeklyGoal":3}],"series":[],"updatedAt":"2026-09-16T10:00:00Z"}"#
        XCTAssertEqual(send("PUT", "/context", body: payload).0, 401)
        let saved = send("PUT", "/context", body: payload, auth: token)
        XCTAssertEqual(saved.0, 200)
        XCTAssertEqual(saved.1["saved"] as? Bool, true)
        XCTAssertEqual(context.current?.creatorName, "Chey")
        XCTAssertEqual(context.current?.pillars.first?.name, "Craft")
        XCTAssertEqual(send("GET", "/admin/context", auth: "admin-secret", loopback: true).0, 404, "the v0.2.x tools' route is gone")
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

    // MARK: - Tools

    /// `iris-bridge mcp`'s one route answers only this Mac with the admin token, and returns the tool result.
    func testTheToolRouteNeedsLoopbackAndTheAdminToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snapshots = SnapshotStore(folder: dir.appendingPathComponent("snapshots"), legacy: context)
        final class NoTurns: TurnContextProvider { func turnContext(threadId: String) -> TurnContext? { nil } }
        let turns = NoTurns()
        let tools = ToolService(reads: IrisReadTools(snapshots: snapshots, hasPairedDevices: { true }),
                                relay: ActionRelay(file: dir.appendingPathComponent("actions.json"), log: nil),
                                approvals: ApprovalBroker(turns: turns, log: nil), snapshots: snapshots, turns: turns)
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: generator, log: nil, tools: tools)
        let body = #"{"name":"iris_workspace_summary","arguments":{},"agent":"claude-code"}"#
        XCTAssertEqual(send("POST", "/admin/v3/tool", body: body, auth: "admin-secret", loopback: false).0, 404)
        XCTAssertEqual(send("POST", "/admin/v3/tool", body: body, auth: token, loopback: true).0, 401)
        let (status, reply) = send("POST", "/admin/v3/tool", body: body, auth: "admin-secret", loopback: true)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(reply["isError"] as? Bool, true)
        XCTAssertEqual(((reply["content"] as? [[String: Any]])?.first?["text"] as? String), IrisReadTools.noSnapshot)
        XCTAssertEqual(send("POST", "/admin/v3/tool", body: #"{"arguments":{}}"#, auth: "admin-secret", loopback: true).0, 400)
        XCTAssertEqual(send("POST", "/admin/v3/tool", body: #"{"name":"x","threadId":"../x"}"#, auth: "admin-secret", loopback: true).0, 400)
    }

    // MARK: - Admin inbox

    func testTheV02xSubmitRouteIsGone() {
        let body = #"{"kind":"post","agent":"claude","post":{"title":"Three shots","pillar":"Craft","platform":"Instagram","format":"Reel"}}"#
        XCTAssertEqual(send("POST", "/admin/inbox", body: body, auth: "admin-secret", loopback: true).0, 404)
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
        inboxClock = { clock }
        inbox = InboxStore(file: dir.appendingPathComponent("inbox.json"), now: inboxClock)
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

    // MARK: - Failure causes (contract §1)

    func testProviderFailureKeepsTheSentenceAndAddsCauseProviderDetailsAndReset() {
        generator.error = ProviderFailure(cause: .usageLimit, provider: "codex", details: "You’ve hit your usage limit.",
                                          resetsAt: Date(timeIntervalSince1970: 1_790_426_460))
        let (status, body) = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token)
        XCTAssertEqual(status, 502)
        XCTAssertEqual(body["cause"] as? String, "usageLimit")
        XCTAssertEqual(body["provider"] as? String, "codex")
        XCTAssertEqual(body["details"] as? String, "You’ve hit your usage limit.")
        XCTAssertEqual(body["resetsAt"] as? String, "2026-09-26T12:41:00Z")
        XCTAssertTrue((body["error"] as? String ?? "").hasPrefix("ChatGPT's usage limit is reached until "), "\(body)")
    }

    func testFailureStatusesStayWhatVersion024Sent() {
        let cases: [(Error, Int, String)] = [
            (ProviderFailure(cause: .signedOut, provider: "codex"), 502, "signedOut"),
            (ProviderFailure(cause: .modelUnavailable, provider: "codex"), 502, "modelUnavailable"),
            (ProviderFailure(cause: .timeout, provider: "codex"), 504, "timeout"),
            (ProviderFailure(cause: .cancelled, provider: "codex"), 502, "cancelled"),
            (BridgeError.timeout, 504, "timeout"),
            (BridgeError.canceled, 502, "cancelled"),
            (BridgeError.message("Sign in first."), 502, "internal"),
        ]
        for (error, expected, cause) in cases {
            generator.error = error
            let (status, body) = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token)
            XCTAssertEqual(status, expected, "\(error)")
            XCTAssertEqual(body["cause"] as? String, cause, "\(error)")
            XCTAssertEqual(body["provider"] as? String, "codex", "\(error)")
            XCTAssertFalse((body["error"] as? String ?? "").isEmpty, "\(error)")
        }
    }

    func testTheRoutersOwnRefusalsCarryACauseAndKeepTheirOldErrorText() {
        let revoked = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: "wrong")
        XCTAssertEqual(revoked.1["error"] as? String, "device-revoked")
        XCTAssertEqual(revoked.1["cause"] as? String, "deviceRevoked")
        XCTAssertEqual(send("POST", "/message", body: "{}", auth: token).1["cause"] as? String, "badRequest")
        XCTAssertEqual(send("GET", "/nope", auth: token).1["cause"] as? String, "badRequest")
        XCTAssertEqual(send("GET", "/status", origin: "https://example.org").1["cause"] as? String, "badRequest")
        router.busy = true
        let busy = send("POST", "/message", body: #"{"provider":"codex","message":"x"}"#, auth: token)
        router.busy = false
        XCTAssertEqual(busy.0, 409)
        XCTAssertEqual(busy.1["cause"] as? String, "busy")
        _ = pairing.issue()
        let wrong = send("POST", "/pair", body: #"{"deviceName":"P","platform":"iphone","proof":"00"}"#)
        XCTAssertEqual(wrong.1["error"] as? String, "wrong-code")
        XCTAssertEqual(wrong.1["cause"] as? String, "badRequest")
    }

    func testAnAlreadyDecidedSubmissionIsABadRequestNotBusy() {
        let submission = submit()
        XCTAssertEqual(send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"approved"}"#, auth: token).0, 200)
        let again = send("POST", "/inbox/\(submission.id)/decision", body: #"{"status":"denied"}"#, auth: token)
        XCTAssertEqual(again.0, 409)
        XCTAssertEqual(again.1["error"] as? String, "Already decided.")
        XCTAssertEqual(again.1["cause"] as? String, "badRequest")
    }

    // MARK: - Authenticated status (contract §2 and §3)

    func testStatusWithoutATokenIsExactlyWhatVersion024Sent() {
        let (status, body) = send("GET", "/status")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(Set(body.keys), ["version", "helperVersion", "hostName", "providers"])
    }

    func testAPairedDeviceAlsoGetsPairedCapabilitiesAndHealth() {
        let (status, body) = send("GET", "/status", auth: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["paired"] as? Bool, true)
        XCTAssertEqual(body["capabilities"] as? [String], BridgeVersion.capabilities)
        XCTAssertEqual(BridgeVersion.capabilities, ["chat", "inbox", "modelSelection", "plannerAccess", "causes", "health", "authStatus", "v3", "effort", "postReferences"])
        let health = body["health"] as? [String: Any]
        let codex = health?["codex"] as? [String: Any]
        XCTAssertEqual(codex?["usage"] as? String, "limited")
        XCTAssertEqual(codex?["resetsAt"] as? String, "2026-09-26T12:41:00Z")
        XCTAssertEqual(codex?["lastErrorCause"] as? String, "usageLimit")
        XCTAssertEqual(codex?["cliVersion"] as? String, "0.155.0-alpha.9.2")
        XCTAssertEqual(codex?["account"] as? String, "Pro")
        let claude = health?["claude"] as? [String: Any]
        XCTAssertEqual(claude?["installed"] as? Bool, false)
        XCTAssertNil(claude?["resetsAt"])
        XCTAssertNil(claude?["lastErrorCause"])
    }

    func testThisMacsAdminTokenGetsHealthButIsNotAPairedDevice() {
        let (status, body) = send("GET", "/status", auth: "admin-secret", loopback: true)
        XCTAssertEqual(status, 200)
        XCTAssertNil(body["paired"])
        XCTAssertNotNil(body["health"])
        XCTAssertNotNil(body["capabilities"])
    }

    func testATokenThatMatchesNothingIsRefusedAtOnce() {
        for (auth, loopback) in [("not-a-token", false), ("admin-secret", false)] {
            let (status, body) = send("GET", "/status", auth: auth, loopback: loopback)
            XCTAssertEqual(status, 401, auth)
            XCTAssertEqual(body["error"] as? String, "device-revoked", auth)
            XCTAssertEqual(body["cause"] as? String, "deviceRevoked", auth)
        }
        _ = try? devices.revoke(id: devices.all[0].id)
        XCTAssertEqual(send("GET", "/status", auth: token).0, 401, "a revoked device learns it from its next status poll")
    }

    /// The `/status` provider entry exactly as Iris builds 106 to 136 decode it (`IrisProviderStatus`).
    private struct AppProviderStatus: Codable { var ready: Bool; var message: String; var auth: String?; var account: String?; var model: String? }
    private struct AppStatus: Decodable { var version: Int; var helperVersion: String; var hostName: String; var providers: [String: AppProviderStatus]
        var capabilities: [String]?; var health: [String: [String: AppHealthValue]]? }
    /// Build 130 on reads each health key with `try? decodeIfPresent`, so any JSON scalar must decode here.
    private enum AppHealthValue: Decodable {
        case bool(Bool), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .string(try c.decode(String.self)) }
        }
    }

    /// A sign-in the Mac could not check is not a sign-out, and older apps show "CLAUDE IS NOT SIGNED IN" with the
    /// sign-in command for `ready: false`. So it is `ready: true` with its own sentence whether or not a turn is
    /// tried on it: "… Trying anyway." when the Mac confirmed a subscription sign-in earlier, "… Try again in a
    /// moment." when it has not, and then `/message` refuses the turn as `providerUnavailable`, which those apps
    /// show as "Claude couldn't answer on your Mac" with Retry. Either way the fields and their types are the ones
    /// 0.2.5 sent.
    func testAnUncheckedSignInKeepsTheShapeOlderAppsDecode() throws {
        let cases: [(ProviderStatus, String)] = [
            (.unknown("claude", tried: true), "Couldn't check Claude's sign-in just now — the Mac may be busy. Trying anyway."),
            (.unknown("claude", tried: false), "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment."),
        ]
        for (unknown, sentence) in cases {
            generator.claudeStatus = unknown
            for auth in [nil, token] as [String?] {
                let (status, data) = raw("GET", "/status", auth: auth)
                XCTAssertEqual(status, 200)
                let decoded = try JSONDecoder().decode(AppStatus.self, from: data)
                XCTAssertEqual(decoded.providers["claude"]?.ready, true, "older apps show ready: false as not signed in")
                XCTAssertEqual(decoded.providers["claude"]?.message, sentence)
                XCTAssertEqual(decoded.providers["codex"]?.ready, true)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let claude = try XCTUnwrap((body["providers"] as? [String: Any])?["claude"] as? [String: Any])
                XCTAssertTrue(Set(claude.keys).isSubset(of: ["ready", "message", "auth", "account", "model"]), "\(claude.keys)")
            }
            let (_, paired) = send("GET", "/status", auth: token)
            let health = (paired["health"] as? [String: Any])?["claude"] as? [String: Any]
            XCTAssertEqual(health?["signInChecked"] as? Bool, false)
            XCTAssertEqual(generator.healthSignIns["claude"], unknown, "health is built from the same answer, not a second check")
        }
    }

    func testAFinishedCheckAddsNothingToTheStatusShape() {
        let (_, body) = send("GET", "/status", auth: token)
        let health = body["health"] as? [String: [String: Any]]
        XCTAssertNil(health?["claude"]?["signInChecked"]); XCTAssertNil(health?["codex"]?["signInChecked"])
        let anonymous = send("GET", "/status").1["providers"] as? [String: [String: Any]]
        XCTAssertEqual(Set(anonymous?["codex"].map { Array($0.keys) } ?? []), ["ready", "message", "model"])
    }

    /// The owner's case, end to end through the real sign-in service: a helper that has just started on a Mac too
    /// busy to answer `claude auth status`. Neither the poll while the first check is still running nor the ones
    /// after it gave up may show Claude as signed out, and a message is refused without a turn and without the
    /// sign-in step: nothing has ruled out an API key yet.
    func testABusyMacIsNeverShownAsSignedOutAndItsMessageIsNotTriedOrCalledSignedOut() throws {
        let runner = BusyMacRunner()
        let service = ProviderService(runner: runner, executableLookup: { $0 == "claude" ? "/usr/local/bin/claude" : nil })
        service.signInRetryPause = 0
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: ServiceGenerator(service), log: nil)
        let couldNotCheck = "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment."
        func assertNotShownSignedOut(_ when: String) throws {
            let (status, data) = raw("GET", "/status", auth: token)
            XCTAssertEqual(status, 200, when)
            let decoded = try JSONDecoder().decode(AppStatus.self, from: data)
            XCTAssertEqual(decoded.providers["claude"]?.ready, true, when)
            XCTAssertEqual(decoded.providers["claude"]?.message, couldNotCheck, when)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let claude = (body["health"] as? [String: Any])?["claude"] as? [String: Any]
            XCTAssertEqual(claude?["signedIn"] as? Bool, true, "the Settings row says \"Signed out\" for false; \(when)")
            XCTAssertEqual(claude?["signInChecked"] as? Bool, false, when)
            XCTAssertEqual(decoded.providers["codex"]?.ready, false, "a missing CLI is still not ready; \(when)")
            XCTAssertEqual(decoded.providers["codex"]?.message, "Install Codex on your Mac first.", when)
        }
        try assertNotShownSignedOut("while the first check is still running")
        XCTAssertEqual(runner.checks, 1)
        runner.release()
        let (status, body) = send("POST", "/message", body: #"{"provider":"claude","message":"Hello"}"#, auth: token)
        XCTAssertEqual(status, 502)
        XCTAssertEqual(body["cause"] as? String, "providerUnavailable", "never signedOut for a Mac nobody could check")
        XCTAssertEqual(body["error"] as? String, couldNotCheck)
        XCTAssertEqual(runner.turns, 0, "no turn runs before a subscription sign-in is confirmed")
        try assertNotShownSignedOut("after the checks gave up")
    }

    /// A sign-in check whose CLI traps SIGTERM and never answers, run for real. The message waits for it no longer
    /// than the limit, and lets go of the helper: the next message is not refused as busy, and neither it nor a
    /// model list waits on the stuck check again.
    func testAMessageOnASignInCheckThatNeverEndsLetsGoOfTheHelperWithinTheLimit() throws {
        let claude = try StubCLI.write("trap '' TERM\nsleep 30")
        let service = ProviderService(runner: ForegroundProcessRunner(), executableLookup: { $0 == "claude" ? claude : nil })
        service.signInRetryPause = 0
        service.signInTimeouts = (first: 0.5, retry: 0.5)
        service.signInWait = 1.5
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: ServiceGenerator(service), log: nil)
        let couldNotCheck = "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment."
        let message = #"{"provider":"claude","message":"Hello"}"#
        let started = Date()
        let (status, body) = send("POST", "/message", body: message, auth: token)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the limit, not the CLI, decides how long the message waits")
        XCTAssertEqual(status, 502)
        XCTAssertEqual(body["cause"] as? String, "providerUnavailable")
        XCTAssertEqual(body["error"] as? String, couldNotCheck)
        let later = Date()
        let (again, againBody) = send("POST", "/message", body: message, auth: token)
        XCTAssertNotEqual(again, 409, "the first message let go of the helper")
        XCTAssertEqual(againBody["cause"] as? String, "providerUnavailable")
        let (models, list) = send("GET", "/models?provider=claude", auth: token)
        XCTAssertEqual(models, 200)
        XCTAssertEqual(list["notice"] as? String, couldNotCheck)
        XCTAssertEqual((list["models"] as? [Any])?.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(later), 1, "past its deadline the stuck check is not waited on again")
    }

    /// The app gives a `/status` poll two seconds. Both providers' checks share one wait instead of taking one each.
    func testAStatusPollWaitsOnceForBothProviders() throws {
        let runner = BusyMacRunner()
        defer { runner.release() }
        let service = ProviderService(runner: runner, executableLookup: { "/iris-test/\($0)" })
        router = Router(fingerprint: fingerprint, hostName: "Studio Mac", adminToken: "admin-secret", devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: ServiceGenerator(service, wait: 0.5), log: nil)
        let started = Date()
        let (status, data) = raw("GET", "/status", auth: token)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9, "one 0.5 s wait for both, not 0.5 s each")
        XCTAssertEqual(status, 200)
        let decoded = try JSONDecoder().decode(AppStatus.self, from: data)
        XCTAssertEqual(decoded.providers["claude"]?.ready, true, "still running, and not shown as signed out")
        XCTAssertEqual(decoded.providers["codex"]?.ready, true)
        XCTAssertEqual(runner.checks, 2, "both checks run side by side")
    }
}

/// `ProviderService` behind the router the way `LiveGenerator` puts it there, polls waiting briefly.
private final class ServiceGenerator: Generator {
    let service: ProviderService
    let wait: TimeInterval
    init(_ service: ProviderService, wait: TimeInterval = 0.05) { self.service = service; self.wait = wait }
    func generate(_ request: MessageRequest) throws -> [String: Any] { try service.generate(request) }
    func status(_ provider: String) -> ProviderStatus { service.status(provider, wait: wait) }
    func statuses(_ providers: [String]) -> [String: ProviderStatus] { service.statuses(providers, wait: wait) }
    func health(_ provider: String) -> ProviderHealth { service.health(provider) }
    func health(_ provider: String, signIn: ProviderStatus) -> ProviderHealth { service.health(provider, signIn: signIn, versionWait: 0) }
    func models(_ provider: String) -> ProviderModelCatalog { service.models(provider) }
    func cancel(_ id: String) {}
}

/// A Mac too busy to answer the sign-in check: each check hangs until `release()`, then times out, as every later
/// one does at once. Anything else is a turn, counted.
private final class BusyMacRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false, checkCount = 0, turnCount = 0
    var checks: Int { lock.lock(); defer { lock.unlock() }; return checkCount }
    var turns: Int { lock.lock(); defer { lock.unlock() }; return turnCount }
    func release() { lock.lock(); released = true; lock.unlock() }
    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        if args.contains("--version") { return ProcessResult(status: 0, stdout: "2.1.274 (Claude Code)", stderr: "") }
        guard args.contains("status") else { lock.lock(); turnCount += 1; lock.unlock(); return ProcessResult(status: 0, stdout: "", stderr: "") }
        lock.lock(); checkCount += 1; lock.unlock()
        while !(lock.withLock { released }) { Thread.sleep(forTimeInterval: 0.01) }
        throw BridgeError.timeout
    }
}
