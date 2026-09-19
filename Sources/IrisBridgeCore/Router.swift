import Foundation

public struct RequestContext { public var sourceAddress: String; public var isLoopback: Bool
    public init(sourceAddress: String, isLoopback: Bool) { self.sourceAddress = sourceAddress; self.isLoopback = isLoopback } }

public protocol Generator {
    func generate(_ request: MessageRequest) throws -> [String: Any]
    func status(_ provider: String) -> ProviderStatus
    func models(_ provider: String) -> ProviderModelCatalog
    func cancel(_ id: String)
}

public final class Router: @unchecked Sendable {
    private let fingerprint: String, hostName: String, adminToken: String
    private let devices: DeviceStore, pairing: PairingCodeStore, generator: Generator, log: BridgeLog?
    // Named `contextStore` inside the router because `context` is already the request context every handler takes.
    private let inbox: InboxStore, contextStore: ContextStore
    private let now: () -> Date
    private let pairLimiter: RateLimiter
    private let lock = NSLock()
    private var completed: [String: (Date, [String: Any])] = [:]
    private var running = false
    public var busy: Bool { get { lock.lock(); defer { lock.unlock() }; return running } set { lock.lock(); running = newValue; lock.unlock() } }

    public init(fingerprint: String, hostName: String, adminToken: String, devices: DeviceStore, pairing: PairingCodeStore,
                inbox: InboxStore, context contextStore: ContextStore, generator: Generator, log: BridgeLog?,
                now: @escaping () -> Date = Date.init) {
        self.fingerprint = fingerprint; self.hostName = hostName; self.adminToken = adminToken
        self.devices = devices; self.pairing = pairing; self.generator = generator; self.log = log; self.now = now
        self.inbox = inbox; self.contextStore = contextStore
        pairLimiter = RateLimiter(limit: 10, per: 60, now: now)
    }

    public func handle(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        if request.header("origin") != nil { return HTTPResponse(status: 403, error: "Browser requests are not allowed.") }
        let bearer = request.header("authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        switch (request.method, request.route) {
        case ("GET", "/status"): return statusResponse(trusted: isTrusted(bearer, context: context))
        case ("POST", "/pair"): return pair(request, context: context)
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

    /// `/status` answers anyone, because the connect screen has to read it before it has a token. Only a
    /// caller we can name gets the full picture: a paired device, or this Mac's own subcommands over
    /// loopback with the admin token. Everyone else is told whether a provider is ready and nothing about
    /// whose account it is or what plan is behind it.
    private func isTrusted(_ bearer: String?, context: RequestContext) -> Bool {
        guard let bearer else { return false }
        if devices.authenticate(token: bearer) != nil { return true }
        return context.isLoopback && PairingProof.constantTimeEqual(bearer, adminToken)
    }

    private func statusResponse(trusted: Bool) -> HTTPResponse {
        func entry(_ provider: String) -> [String: Any] {
            let s = generator.status(provider)
            var dict: [String: Any] = ["ready": s.ready]
            dict["model"] = s.model
            guard trusted else {
                // The not-ready copy names no account and no plan, so it is safe to repeat verbatim; the
                // ready copy carries the subscription tier, so it is replaced.
                dict["message"] = s.ready ? "Signed in." : s.message
                return dict
            }
            dict["message"] = s.message
            dict["auth"] = s.auth; dict["account"] = s.account
            return dict
        }
        return HTTPResponse(status: 200, json: ["version": BridgeVersion.protocolVersion, "helperVersion": BridgeVersion.current, "hostName": hostName,
                                                "providers": ["claude": entry("claude"), "codex": entry("codex")]])
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
            return HTTPResponse(status: 400, json: ["error": "wrong-code", "attemptsLeft": left])
        case .expired: return HTTPResponse(status: 400, error: "expired")
        case .noCode: return HTTPResponse(status: 400, error: "no-code")
        }
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
        } catch BridgeError.timeout {
            log?.error("message \(parsed.provider) timeout"); return HTTPResponse(status: 504, error: BridgeError.timeout.errorDescription!)
        } catch BridgeError.canceled {
            log?.info("message \(parsed.provider) canceled"); return HTTPResponse(status: 502, error: BridgeError.canceled.errorDescription!)
        } catch let error as BridgeError {
            log?.error("message \(parsed.provider) failed: \(error.errorDescription ?? "")"); return HTTPResponse(status: 502, error: String((error.errorDescription ?? "").prefix(300)))
        } catch {
            log?.error("message \(parsed.provider) unreadable"); return HTTPResponse(status: 502, error: "The provider response could not be read. No post was changed.")
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

    private func admin(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.route) {
        case ("POST", "/admin/pair-code"):
            let issued = pairing.issue()
            return HTTPResponse(status: 200, json: ["code": issued.code, "expiresAt": ISO8601DateFormatter().string(from: issued.expiresAt)])
        case ("GET", "/admin/devices"):
            let f = ISO8601DateFormatter()
            return HTTPResponse(status: 200, json: ["devices": devices.all.map { ["id": $0.id, "name": $0.name, "platform": $0.platform, "pairedAt": f.string(from: $0.pairedAt), "lastSeenAt": f.string(from: $0.lastSeenAt)] }])
        case ("DELETE", let path) where path.hasPrefix("/admin/devices/"):
            let id = String(path.dropFirst("/admin/devices/".count))
            return (try? devices.revoke(id: id)) == true ? HTTPResponse(status: 200, json: ["revoked": id]) : HTTPResponse(status: 404, error: "unknown-device")
        case ("POST", "/admin/inbox"): return adminSubmit(request)
        case ("POST", "/admin/inbox/prune"):
            // `iris-bridge inbox clear-decided`. Thirty days is the same window `all(since:)` shows by
            // default, so pruning never takes away something the app would still have listed.
            do { return HTTPResponse(status: 200, json: ["removed": try inbox.pruneDecided(olderThan: 30 * 24 * 60 * 60)]) }
            catch { return HTTPResponse(status: 500, error: "Could not clear decided submissions.") }
        case ("GET", "/admin/inbox"):
            let all = request.query["status"] == "all"
            return Self.encoded(200, all ? inbox.all(since: Date(timeIntervalSince1970: 0)) : inbox.pending)
        case ("GET", "/admin/context"):
            guard let current = contextStore.current else {
                // Two different problems with two different fixes. A Mac nobody has paired with is where
                // every new install starts, and the agent is the only one in a position to say so.
                return HTTPResponse(status: 404, error: devices.all.isEmpty ? Self.notPairedSentence
                                                                            : "No workspace context yet. Open Iris on a paired device.")
            }
            return Self.encoded(200, current)
        default: return HTTPResponse(status: 404, error: "Not found")
        }
    }

    public static let notPairedSentence = "Iris is not connected to this Mac yet. Ask the creator to run `iris-bridge pair` in Terminal, then open Iris, choose this Mac under Macs nearby and enter the code. Try again once they have."

    // MARK: - Inbox and context

    private struct InboxPayload: Encodable { var submissions: [Submission]; var now: Date }
    private struct DecisionBody: Decodable { var status: String; var comment: String? }
    private struct SubmitBody: Decodable {
        var kind: SubmissionKind
        var post: SubmittedPost?
        var series: SubmittedSeries?
        var archive: ArchiveProposal?
        var agent: String?
        var note: String?
        var revisionOf: String?
    }

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
            return HTTPResponse(status: error == .notFound ? 404 : 409, error: error.localizedDescription)
        } catch BridgeError.message("Not found.") {
            return HTTPResponse(status: 404, error: "Not found.")
        } catch BridgeError.message("Already decided.") {
            return HTTPResponse(status: 409, error: "Already decided.")
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

    private func adminSubmit(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(SubmitBody.self, from: request.body) else {
            return HTTPResponse(status: 400, error: "Could not read that submission.")
        }
        do {
            let submission: Submission
            if body.kind == .archive {
                guard let archive = body.archive, body.post == nil, body.series == nil, body.revisionOf == nil else {
                    return HTTPResponse(status: 400, error: "Could not read that archive proposal.")
                }
                submission = try inbox.submitArchive(archive, agent: body.agent ?? "agent", note: body.note)
            } else {
                guard body.archive == nil else { return HTTPResponse(status: 400, error: "Archive data belongs in an archive proposal.") }
                submission = try inbox.submit(kind: body.kind, post: body.post, series: body.series,
                                               agent: body.agent ?? "agent", note: body.note, revisionOf: body.revisionOf)
            }
            log?.info("inbox received \(submission.kind.rawValue) \(submission.id) from \(submission.agent)")
            return Self.encoded(200, submission)
        } catch let error as BridgeError {
            return HTTPResponse(status: 400, error: error.errorDescription ?? "Could not accept that submission.")
        } catch {
            return HTTPResponse(status: 500, error: "Could not save that submission.")
        }
    }
}
