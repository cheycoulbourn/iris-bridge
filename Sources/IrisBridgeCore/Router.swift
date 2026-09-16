import Foundation

public struct RequestContext { public var sourceAddress: String; public var isLoopback: Bool
    public init(sourceAddress: String, isLoopback: Bool) { self.sourceAddress = sourceAddress; self.isLoopback = isLoopback } }

public protocol Generator {
    func generate(_ request: MessageRequest) throws -> [String: Any]
    func status(_ provider: String) -> ProviderStatus
    func cancel(_ id: String)
}

public final class Router: @unchecked Sendable {
    private let fingerprint: String, hostName: String, adminToken: String
    private let devices: DeviceStore, pairing: PairingCodeStore, generator: Generator, log: BridgeLog?
    private let now: () -> Date
    private let pairLimiter: RateLimiter
    private let lock = NSLock()
    private var completed: [String: (Date, [String: Any])] = [:]
    private var running = false
    public var busy: Bool { get { lock.lock(); defer { lock.unlock() }; return running } set { lock.lock(); running = newValue; lock.unlock() } }

    public init(fingerprint: String, hostName: String, adminToken: String, devices: DeviceStore, pairing: PairingCodeStore, generator: Generator, log: BridgeLog?, now: @escaping () -> Date = Date.init) {
        self.fingerprint = fingerprint; self.hostName = hostName; self.adminToken = adminToken
        self.devices = devices; self.pairing = pairing; self.generator = generator; self.log = log; self.now = now
        pairLimiter = RateLimiter(limit: 10, per: 60, now: now)
    }

    public func handle(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        if request.header("origin") != nil { return HTTPResponse(status: 403, error: "Browser requests are not allowed.") }
        let bearer = request.header("authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        switch (request.method, request.path) {
        case ("GET", "/status"): return statusResponse(trusted: isTrusted(bearer, context: context))
        case ("POST", "/pair"): return pair(request, context: context)
        case ("POST", "/message"): return authenticated(bearer) { _ in self.message(request) }
        case ("POST", "/cancel"): return authenticated(bearer) { _ in self.cancel(request) }
        case ("DELETE", "/device"): return authenticated(bearer) { device in
            _ = try? self.devices.revoke(id: device.id); self.log?.info("device removed itself \(device.id)")
            return HTTPResponse(status: 200, json: ["removed": true]) }
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

    private func cancel(_ request: HTTPRequest) -> HTTPResponse {
        guard request.body.count < 1024, let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let id = body["id"] as? String, id.count < 100 else { return HTTPResponse(status: 400, error: "Could not cancel") }
        generator.cancel(id)
        return HTTPResponse(status: 200, json: ["canceled": true])
    }

    private func admin(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/admin/pair-code"):
            let issued = pairing.issue()
            return HTTPResponse(status: 200, json: ["code": issued.code, "expiresAt": ISO8601DateFormatter().string(from: issued.expiresAt)])
        case ("GET", "/admin/devices"):
            let f = ISO8601DateFormatter()
            return HTTPResponse(status: 200, json: ["devices": devices.all.map { ["id": $0.id, "name": $0.name, "platform": $0.platform, "pairedAt": f.string(from: $0.pairedAt), "lastSeenAt": f.string(from: $0.lastSeenAt)] }])
        case ("DELETE", let path) where path.hasPrefix("/admin/devices/"):
            let id = String(path.dropFirst("/admin/devices/".count))
            return (try? devices.revoke(id: id)) == true ? HTTPResponse(status: 200, json: ["revoked": id]) : HTTPResponse(status: 404, error: "unknown-device")
        default: return HTTPResponse(status: 404, error: "Not found")
        }
    }
}
