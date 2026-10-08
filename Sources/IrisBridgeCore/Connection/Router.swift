import Foundation

public struct RequestContext { public var sourceAddress: String; public var isLoopback: Bool
    public init(sourceAddress: String, isLoopback: Bool) { self.sourceAddress = sourceAddress; self.isLoopback = isLoopback } }

public protocol Generator {
    func generate(_ request: MessageRequest) throws -> [String: Any]
    func status(_ provider: String) -> ProviderStatus
    /// Several providers' sign-in answers at once, as `/status` asks for them: one wait for all of them, not one each.
    func statuses(_ providers: [String]) -> [String: ProviderStatus]
    func health(_ provider: String) -> ProviderHealth
    /// Health from the sign-in answer `/status` already has, so one poll checks each CLI once.
    func health(_ provider: String, signIn: ProviderStatus) -> ProviderHealth
    func models(_ provider: String) -> ProviderModelCatalog
    func cancel(_ id: String)
}

extension Generator {
    public func statuses(_ providers: [String]) -> [String: ProviderStatus] {
        Dictionary(uniqueKeysWithValues: providers.map { ($0, status($0)) })
    }
    public func health(_ provider: String, signIn: ProviderStatus) -> ProviderHealth { health(provider) }
}

public final class Router: @unchecked Sendable {
    private let fingerprint: String, hostName: String, adminToken: String
    private let devices: DeviceStore, pairing: PairingCodeStore, generator: Generator, log: BridgeLog?
    // Named `contextStore` inside the router because `context` is already the request context every handler takes.
    private let inbox: InboxStore, contextStore: ContextStore
    private let now: () -> Date
    private let pairLimiter: RateLimiter
    private let qrPairing: PairingQRStore
    private var pairingURL: String
    private let localApproval: (String) -> Bool
    private let localPairLimiter: RateLimiter
    private let localPairLock = NSLock()
    private var localPairPending = false
    private var localPairNextAllowed = Date.distantPast
    private struct LocalApproval { let tokenHash: String; let confirmation: String; let name: String; let expiresAt: Date }
    private var approvedLocalPairing: LocalApproval?
    private let localCompletionLimiter: RateLimiter
    /// The v3 tool path for `iris-bridge mcp` (`POST /admin/v3/tool`). Nil only in tests that never call a tool.
    private let tools: ToolService?
    private let lock = NSLock()
    private var completed: [String: (Date, [String: Any])] = [:]
    private var running = false
    public var busy: Bool { get { lock.lock(); defer { lock.unlock() }; return running } set { lock.lock(); running = newValue; lock.unlock() } }

    public init(fingerprint: String, hostName: String, adminToken: String, devices: DeviceStore, pairing: PairingCodeStore,
                inbox: InboxStore, context contextStore: ContextStore, generator: Generator, log: BridgeLog?,
                tools: ToolService? = nil, now: @escaping () -> Date = Date.init,
                pairingURL: String = "https://\(HostName.localHostName()):48731",
                localApproval: @escaping (String) -> Bool = LocalPairingApproval.request) {
        self.fingerprint = fingerprint; self.hostName = hostName; self.adminToken = adminToken; self.tools = tools
        self.devices = devices; self.pairing = pairing; self.generator = generator; self.log = log; self.now = now
        self.inbox = inbox; self.contextStore = contextStore
        pairLimiter = RateLimiter(limit: 10, per: 60, now: now)
        qrPairing = PairingQRStore(now: now); self.pairingURL = pairingURL; self.localApproval = localApproval
        localPairLimiter = RateLimiter(limit: 3, per: 60, now: now)
        localCompletionLimiter = RateLimiter(limit: 10, per: 60, now: now)
    }

    /// Called after a listener chooses its port, including port zero used by isolated tests.
    func updateListeningPort(_ port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard var url = URLComponents(string: pairingURL) else { return }
        url.port = Int(port)
        if let value = url.string { pairingURL = value }
    }

    public func handle(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        if request.header("origin") != nil { return HTTPResponse(status: 403, error: "Browser requests are not allowed.") }
        let bearer = request.header("authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        switch (request.method, request.route) {
        case ("GET", "/status"): return status(bearer: bearer, context: context)
        case ("POST", "/pair"): return pair(request, context: context)
        case ("POST", "/pair/local"): return pairLocal(request, context: context)
        case ("POST", "/pair/local/complete"): return completeLocalPairing(request, context: context)
        case ("POST", "/pair/qr"): return pairQR(request, context: context)
        case ("GET", "/models"): return authenticated(bearer) { _ in self.models(request) }
        case ("POST", "/message"): return authenticated(bearer) { _ in self.message(request) }
        case ("POST", "/cancel"): return authenticated(bearer) { _ in self.cancel(request) }
        case ("DELETE", "/device"): return authenticated(bearer) { device in
            _ = try? self.devices.revoke(id: device.id); self.log?.info("device removed itself \(device.id)")
            return HTTPResponse(status: 200, json: ["removed": true]) }
        case ("GET", "/inbox"): return authenticated(bearer) { _ in self.inboxList(request) }
        case ("POST", let route) where route.hasPrefix("/inbox/") && route.hasSuffix("/decision"):
            let id = String(route.dropFirst("/inbox/".count).dropLast("/decision".count))
            return authenticated(bearer) { _ in self.decide(request, id: id) }
        case ("PUT", "/context"): return authenticated(bearer) { _ in self.saveContext(request) }
        case (_, let path) where path.hasPrefix("/admin/"):
            guard context.isLoopback else { return HTTPResponse(status: 404, error: "Not found") }
            guard let bearer, PairingProof.constantTimeEqual(bearer, adminToken) else { return HTTPResponse(status: 401, error: "admin-token") }
            return admin(request)
        default: return HTTPResponse(status: 404, error: "Not found")
        }
    }

    private func authenticated(_ bearer: String?, _ body: (PairedDevice) -> HTTPResponse) -> HTTPResponse {
        guard let bearer, let device = devices.authenticate(token: bearer) else { return HTTPResponse(status: 401, error: "device-revoked") }
        return body(device)
    }

    /// Who asked for `/status`, which decides how much it says (contract §2).
    private enum StatusCaller { case anonymous, device, admin }

    /// `/status` answers anyone, because the connect screen reads it before it has a token, and to a caller
    /// with no token it says exactly what 0.2.4 said. A paired device also learns that it is paired, what this
    /// helper can do and how each provider is. This Mac's own subcommands (loopback plus the admin token) get
    /// the same without `paired`. A token that matches nothing is refused, so a revoked device finds out on its
    /// next poll instead of at its next message (I4); `error` keeps the `device-revoked` code older apps match.
    private func status(bearer: String?, context: RequestContext) -> HTTPResponse {
        guard let bearer else { return statusResponse(for: .anonymous) }
        if devices.authenticate(token: bearer) != nil { return statusResponse(for: .device) }
        if context.isLoopback, PairingProof.constantTimeEqual(bearer, adminToken) { return statusResponse(for: .admin) }
        return HTTPResponse(status: 401, error: "device-revoked", cause: .deviceRevoked)
    }

    private func statusResponse(for caller: StatusCaller) -> HTTPResponse {
        let trusted = caller != .anonymous
        // One wait for both providers: the app gives the whole poll two seconds.
        let signIns = generator.statuses(["claude", "codex"])
        func entry(_ provider: String) -> [String: Any] {
            let s = signIns[provider]!
            // `ready` is what the app shows: false is "not signed in" with the sign-in command in every Iris app, so
            // a sign-in the Mac could not check is true here even when `/message` will not try a turn on it.
            var dict: [String: Any] = ["ready": s.shownSignedIn]
            dict["model"] = s.model
            guard trusted else {
                // The not-ready and couldn't-check copy names no account and no plan, so it is safe to repeat
                // verbatim; the signed-in copy carries the subscription tier, so it is replaced.
                dict["message"] = s.ready && s.checked ? "Signed in." : s.message
                return dict
            }
            dict["message"] = s.message
            dict["auth"] = s.auth; dict["account"] = s.account
            return dict
        }
        var body: [String: Any] = ["version": BridgeVersion.protocolVersion, "helperVersion": BridgeVersion.current, "hostName": hostName,
                                   "providers": ["claude": entry("claude"), "codex": entry("codex")]]
        if trusted {
            body["capabilities"] = BridgeVersion.capabilities
            body["health"] = ["claude": generator.health("claude", signIn: signIns["claude"]!).json,
                              "codex": generator.health("codex", signIn: signIns["codex"]!).json]
        }
        if caller == .device { body["paired"] = true }
        return HTTPResponse(status: 200, json: body)
    }

    private func pair(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        guard pairLimiter.allow(context.sourceAddress) else { return HTTPResponse(status: 429, error: "too-many-attempts") }
        guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let proof = body["proof"] as? String, let name = body["deviceName"] as? String else { return HTTPResponse(status: 400, error: "bad-request") }
        let platform = body["platform"] as? String ?? "iphone"
        switch pairing.redeem(proof: proof, fingerprint: fingerprint) {
        case .accepted:
            guard let (device, token) = try? devices.issue(name: name, platform: platform) else { return HTTPResponse(status: 500, error: "Could not save the device.") }
            log?.info("paired device \(device.id) (\(device.platform))")
            return HTTPResponse(status: 200, json: ["deviceID": device.id, "token": token, "hostName": hostName])
        case .wrongCode(let left):
            log?.info("pairing attempt failed from \(context.sourceAddress), \(left) left")
            return HTTPResponse(status: 400, json: ["error": "wrong-code", "attemptsLeft": left, "cause": FailureCause.badRequest.rawValue])
        case .expired: return HTTPResponse(status: 400, error: "expired")
        case .noCode: return HTTPResponse(status: 400, error: "no-code")
        }
    }

    private static func isJSON(_ request: HTTPRequest) -> Bool {
        request.header("content-type")?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// No network peer or browser can invoke the native prompt. All valid local requests share the guard,
    /// so changing addresses cannot open concurrent prompts or bypass the cooldown.
    private func pairLocal(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        guard context.isLoopback else { return HTTPResponse(status: 403, error: "local-pairing-only") }
        guard Self.isJSON(request) else { return HTTPResponse(status: 415, error: "json-required") }
        guard request.body.count <= 1024,
              let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let name = body["deviceName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              body["platform"] as? String == "mac",
              let confirmation = body["confirmation"] as? String, LocalPairingApproval.valid(confirmation) else { return HTTPResponse(status: 400, error: "bad-request") }
        localPairLock.lock()
        guard !localPairPending else { localPairLock.unlock(); return HTTPResponse(status: 409, error: "local-pairing-busy") }
        guard now() >= localPairNextAllowed, localPairLimiter.allow("local") else {
            localPairLock.unlock(); return HTTPResponse(status: 429, error: "too-many-attempts")
        }
        localPairPending = true
        localPairLock.unlock()
        defer {
            localPairLock.lock(); localPairPending = false; localPairNextAllowed = now().addingTimeInterval(10); localPairLock.unlock()
        }
        guard localApproval(confirmation) else { return HTTPResponse(status: 403, error: "local-pairing-declined") }
        let approvalToken = DeviceStore.randomToken(), expiresAt = now().addingTimeInterval(60)
        localPairLock.lock()
        approvedLocalPairing = LocalApproval(tokenHash: DeviceStore.hash(approvalToken), confirmation: confirmation.lowercased(), name: name, expiresAt: expiresAt)
        localPairLock.unlock()
        return HTTPResponse(status: 200, json: ["approvalToken": approvalToken, "expiresAt": ISO8601DateFormatter().string(from: expiresAt)])
    }

    private func completeLocalPairing(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        guard context.isLoopback else { return HTTPResponse(status: 403, error: "local-pairing-only") }
        guard Self.isJSON(request) else { return HTTPResponse(status: 415, error: "json-required") }
        guard localCompletionLimiter.allow("local") else { return HTTPResponse(status: 429, error: "too-many-attempts") }
        guard request.body.count <= 1024,
              let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let token = body["approvalToken"] as? String, !token.isEmpty, token.count <= 128,
              let confirmation = body["confirmation"] as? String, LocalPairingApproval.valid(confirmation) else {
            return HTTPResponse(status: 400, error: "bad-request")
        }
        localPairLock.lock()
        guard let approved = approvedLocalPairing, now() < approved.expiresAt else {
            approvedLocalPairing = nil; localPairLock.unlock()
            return HTTPResponse(status: 403, error: "local-approval-expired")
        }
        guard PairingProof.constantTimeEqual(DeviceStore.hash(token), approved.tokenHash),
              PairingProof.constantTimeEqual(confirmation.lowercased(), approved.confirmation) else {
            localPairLock.unlock(); return HTTPResponse(status: 403, error: "local-approval-invalid")
        }
        approvedLocalPairing = nil
        localPairLock.unlock()
        return issueDevice(name: approved.name, platform: "mac")
    }

    private func pairQR(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        guard pairLimiter.allow(context.sourceAddress) else { return HTTPResponse(status: 429, error: "too-many-attempts") }
        guard Self.isJSON(request) else { return HTTPResponse(status: 415, error: "json-required") }
        guard request.body.count <= 1024,
              let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let proof = body["proof"] as? String, proof.count == 64, proof.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let name = body["deviceName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              let platform = body["platform"] as? String, ["mac", "iphone", "ipad"].contains(platform) else {
            return HTTPResponse(status: 400, error: "bad-request")
        }
        switch qrPairing.redeem(proof: proof, fingerprint: fingerprint) {
        case .accepted: return issueDevice(name: name, platform: platform)
        case .invalid: return HTTPResponse(status: 400, error: "qr-invalid")
        case .expired: return HTTPResponse(status: 400, error: "qr-expired")
        case .unavailable: return HTTPResponse(status: 400, error: "qr-expired")
        }
    }

    private func issueDevice(name: String, platform: String) -> HTTPResponse {
        guard let (device, token) = try? devices.issue(name: name, platform: platform) else {
            return HTTPResponse(status: 500, error: "Could not save the device.")
        }
        log?.info("paired device \(device.id) (\(device.platform))")
        return HTTPResponse(status: 200, json: ["deviceID": device.id, "token": token, "hostName": hostName])
    }

    private func message(_ request: HTTPRequest) -> HTTPResponse {
        let parsed: MessageRequest
        do { parsed = try MessageValidation.parse(request.body) } catch { return HTTPResponse(status: 400, error: (error as? BridgeError)?.errorDescription ?? "Could not read this message.") }
        lock.lock()
        if let id = parsed.id, let cached = completed[id], now().timeIntervalSince(cached.0) < 600 { lock.unlock(); return HTTPResponse(status: 200, json: cached.1) }
        guard !running else { lock.unlock(); return HTTPResponse(status: 409, error: "Iris is still answering another message. Try again when it finishes.") }
        running = true; lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        let started = now()
        do {
            let answer = try generator.generate(parsed)
            if let id = parsed.id {
                lock.lock()
                completed[id] = (now(), answer)
                completed = completed.filter { now().timeIntervalSince($0.value.0) < 600 }
                while completed.count > 20, let oldest = completed.min(by: { $0.value.0 < $1.value.0 }) { completed[oldest.key] = nil }
                lock.unlock()
            }
            log?.info("message \(parsed.provider) ok in \(Int(now().timeIntervalSince(started)))s")
            return HTTPResponse(status: 200, json: answer)
        } catch {
            let failure = Self.failure(from: error, provider: parsed.provider)
            var line = "message \(parsed.provider) \(failure.cause.rawValue) after \(Int(now().timeIntervalSince(started)))s"
            if let details = failure.details { line += ": " + OneLineText.clean(details, limit: 300) }
            if failure.cause == .cancelled { log?.info(line) } else { log?.error(line) }
            return HTTPResponse(failure: failure, now: now())
        }
    }

    private func models(_ request: HTTPRequest) -> HTTPResponse {
        guard let provider = request.query["provider"], ["claude", "codex"].contains(provider) else {
            return HTTPResponse(status: 400, error: "Choose Claude Code or Codex.")
        }
        let catalog = generator.models(provider)
        guard catalog.provider == provider else { return HTTPResponse(status: 502, error: "Could not read model choices. Keep Automatic selected and try again.") }
        return Self.encoded(200, catalog)
    }

    private func cancel(_ request: HTTPRequest) -> HTTPResponse {
        guard request.body.count < 1024, let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let id = body["id"] as? String, id.count < 100 else { return HTTPResponse(status: 400, error: "Could not cancel") }
        generator.cancel(id)
        return HTTPResponse(status: 200, json: ["canceled": true])
    }

    /// Everything a generator can throw, as the one failure shape the wire carries (contract §1). A bare
    /// `BridgeError.message` keeps its 0.2.4 sentence, capped at the same 300 characters.
    static func failure(from error: Error, provider: String) -> ProviderFailure {
        if let failure = error as? ProviderFailure { return failure }
        switch error as? BridgeError {
        case .timeout?: return ProviderFailure(cause: .timeout, provider: provider)
        case .canceled?: return ProviderFailure(cause: .cancelled, provider: provider)
        case .message(let text)?: return ProviderFailure(cause: .internal, provider: provider, message: String(text.prefix(300)))
        case nil: return ProviderFailure(cause: .internal, provider: provider, message: "The provider response could not be read. No post was changed.")
        }
    }

    private func admin(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.route) {
        case ("POST", "/admin/pair-qr"):
            lock.lock(); let url = pairingURL; lock.unlock()
            return Self.encoded(200, qrPairing.issue(url: url, fingerprint: fingerprint, hostName: hostName))
        case ("POST", "/admin/pair-code"):
            let issued = pairing.issue()
            return HTTPResponse(status: 200, json: ["code": issued.code, "expiresAt": ISO8601DateFormatter().string(from: issued.expiresAt)])
        case ("GET", "/admin/devices"):
            let f = ISO8601DateFormatter()
            return HTTPResponse(status: 200, json: ["devices": devices.all.map { ["id": $0.id, "name": $0.name, "platform": $0.platform, "pairedAt": f.string(from: $0.pairedAt), "lastSeenAt": f.string(from: $0.lastSeenAt)] }])
        case ("DELETE", let path) where path.hasPrefix("/admin/devices/"):
            let id = String(path.dropFirst("/admin/devices/".count))
            return (try? devices.revoke(id: id)) == true ? HTTPResponse(status: 200, json: ["revoked": id]) : HTTPResponse(status: 404, error: "unknown-device")
        case ("POST", "/admin/v3/tool"):
            return tool(request)
        case ("POST", "/admin/inbox/prune"):
            // `iris-bridge inbox clear-decided`. Thirty days is the same window `all(since:)` shows by
            // default, so pruning never takes away something the app would still have listed.
            do { return HTTPResponse(status: 200, json: ["removed": try inbox.pruneDecided(olderThan: 30 * 24 * 60 * 60)]) }
            catch { return HTTPResponse(status: 500, error: "Could not clear decided submissions.") }
        case ("GET", "/admin/inbox"):
            let all = request.query["status"] == "all"
            return Self.encoded(200, all ? inbox.all(since: Date(timeIntervalSince1970: 0)) : inbox.pending)
        default: return HTTPResponse(status: 404, error: "Not found")
        }
    }

    /// `iris-bridge mcp`'s one route: `{name, arguments, threadId?, turnId?, agent}` in, the MCP `tools/call` result out.
    private func tool(_ request: HTTPRequest) -> HTTPResponse {
        guard let tools else { return HTTPResponse(status: 404, error: "Not found") }
        guard let body = try? JSONValue.decode(request.body), let name = body["name"]?.stringValue, !name.isEmpty else {
            return HTTPResponse(status: 400, error: "Could not read that tool call.")
        }
        let threadId = body["threadId"]?.stringValue, turnId = body["turnId"]?.stringValue
        if let threadId, !StreamIdentifiers.isThreadID(threadId) { return HTTPResponse(status: 400, error: "Could not read that tool call.") }
        if let turnId, !StreamIdentifiers.isToken(turnId) { return HTTPResponse(status: 400, error: "Could not read that tool call.") }
        let agent = OneLineText.clean(body["agent"]?.stringValue ?? "agent", limit: 80)
        let result = tools.call(name: name, arguments: body["arguments"]?.objectValue ?? [:], threadId: threadId, turnId: turnId,
                                agent: agent.isEmpty ? "agent" : agent)
        return HTTPResponse(status: 200, data: result.json.encoded())
    }

    public static let notPairedSentence = "Iris is not connected to this Mac yet. Ask the creator to run `iris-bridge pair` in Terminal, then open Iris, choose this Mac under Macs nearby and enter the code. Try again once they have."

    // MARK: - Inbox and context

    private struct InboxPayload: Encodable { var submissions: [Submission]; var now: Date }
    private struct DecisionBody: Decodable { var status: String; var comment: String? }

    /// Everything the inbox returns is `Codable`, so it is encoded here rather than hand-built as a
    /// dictionary. Dates go out as ISO 8601, the shape the app and the stores already agree on.
    private static func encoded(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return HTTPResponse(status: 500, error: "Could not write that reply.") }
        return HTTPResponse(status: status, data: data)
    }

    /// ISO 8601 with or without fractional seconds. Anything else is not a date we can act on.
    private static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private func inboxList(_ request: HTTPRequest) -> HTTPResponse {
        // A `since` we cannot read is dropped rather than refused: the app is polling, and a stuck clock or a
        // stale string should cost it a bigger reply, not the Inbox.
        let since = request.query["since"].flatMap(Self.parseTimestamp)
        return Self.encoded(200, InboxPayload(submissions: inbox.all(since: since), now: now()))
    }

    private func decide(_ request: HTTPRequest, id: String) -> HTTPResponse {
        guard request.body.count < 64 * 1024, let body = try? JSONDecoder().decode(DecisionBody.self, from: request.body) else {
            return HTTPResponse(status: 400, error: "Could not read that decision.")
        }
        guard let status = SubmissionStatus(rawValue: body.status), status != .pending else {
            return HTTPResponse(status: 400, error: "That is not a decision Iris can record.")
        }
        let trimmed = body.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let comment = trimmed.isEmpty ? nil : String(trimmed.prefix(SubmissionLimits.noteCharacters))
        do {
            let updated = try inbox.decide(id: id, status: status, comment: comment)
            log?.info("inbox \(id) \(status.rawValue)")
            return Self.encoded(200, updated)
        } catch let error as InboxError {
            // 404 for a submission that is not here, 409 for one already decided. Anything else reached the store
            // and failed while writing, which is a server problem, not a missing submission.
            // A decision on something already decided is the caller's mistake, not a busy helper.
            return HTTPResponse(status: error == .notFound ? 404 : 409, error: error.localizedDescription, cause: .badRequest)
        } catch BridgeError.message("Not found.") {
            return HTTPResponse(status: 404, error: "Not found.", cause: .badRequest)
        } catch BridgeError.message("Already decided.") {
            return HTTPResponse(status: 409, error: "Already decided.", cause: .badRequest)
        } catch {
            log?.error("inbox \(id) could not be saved")
            return HTTPResponse(status: 500, error: "Iris Bridge could not save that decision. Try again.")
        }
    }

    private func saveContext(_ request: HTTPRequest) -> HTTPResponse {
        guard request.body.count <= HTTPRequestParser.maximumBodyBytes else {
            return HTTPResponse(status: 413, error: "That workspace snapshot is too large.")
        }
        // The app writes `updatedAt` with fractional seconds; `.iso8601` alone is not guaranteed to read those,
        // so the snapshot gets the same tolerance `since` does.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseTimestamp(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Not an ISO 8601 timestamp."))
            }
            return date
        }
        guard let snapshot = try? decoder.decode(WorkspaceContext.self, from: request.body) else {
            return HTTPResponse(status: 400, error: "Could not read that workspace snapshot.")
        }
        // Keep the original small context budget for older apps while allowing the additive planner snapshot
        // its documented 16 MiB ceiling. This is checked after decoding so an oversized legacy context does
        // not gain room merely by adding an unrelated key.
        guard snapshot.planner != nil || request.body.count <= 256 * 1024 else {
            return HTTPResponse(status: 413, error: "That workspace snapshot is too large.")
        }
        do { try contextStore.save(snapshot) } catch {
            log?.error("could not save workspace context")
            return HTTPResponse(status: 500, error: "Could not save that workspace snapshot.")
        }
        return HTTPResponse(status: 200, json: ["saved": true])
    }
}
