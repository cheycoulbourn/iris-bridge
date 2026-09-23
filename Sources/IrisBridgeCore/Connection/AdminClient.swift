import Foundation
import Security
import CryptoKit

private final class PinnedDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        completionHandler(digest == fingerprint ? .useCredential : .cancelAuthenticationChallenge, digest == fingerprint ? URLCredential(trust: trust) : nil)
    }
}

/// Why this Mac's own helper could not be reached over loopback. Typed rather than a sentence because two
/// callers word each case differently: Terminal tells the person what to run, and an MCP tool result tells the
/// agent what to ask the person for (I7).
public enum AdminClientError: Error, Equatable, LocalizedError {
    /// No certificate or admin token on disk: nothing has been set up here.
    case notInstalled
    /// Nothing answered on the loopback port.
    case notRunning
    /// Something accepted the connection and did not answer within the request timeout.
    case timedOut
    /// The helper that answered is not serving the certificate on disk: a stale or second install.
    case certificateMismatch

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Iris Bridge has not been set up on this Mac. Run the install command, then try again."
        case .notRunning: return "Iris Bridge is not running on this Mac. Run the install command again to start it."
        case .timedOut: return "Iris Bridge did not answer within 5 seconds. It may be busy; try again in a moment."
        case .certificateMismatch: return "Iris Bridge's certificate does not match. Run `iris-bridge uninstall`, then install again."
        }
    }

    /// The same failure, worded for an agent reading a tool result.
    public var agentMessage: String {
        switch self {
        case .notInstalled: return "Iris Bridge is not set up on this Mac. Ask the creator to run the Iris Bridge install command in Terminal."
        case .notRunning: return "Iris Bridge is not running. Run `iris-bridge status` on this Mac."
        case .timedOut: return "Iris Bridge is running but did not answer in time. Try the tool again in a moment."
        case .certificateMismatch: return "Iris Bridge's certificate on disk does not match the running helper. Ask the creator to run the Iris Bridge install command again."
        }
    }
}

public final class AdminClient {
    private let base: URL
    private let token: String
    private let session: URLSession
    /// A missing or unreadable certificate or admin token means nothing usable was ever set up here.
    public init(paths: BridgePaths, port: UInt16) throws {
        guard let pem = try? String(contentsOf: paths.certificate, encoding: .utf8),
              let storedToken = try? String(contentsOf: paths.adminToken, encoding: .utf8),
              let fingerprint = try? CertificateManager.fingerprint(pem: pem) else { throw AdminClientError.notInstalled }
        token = storedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        base = URL(string: "https://127.0.0.1:\(port)")!
        session = URLSession(configuration: .ephemeral, delegate: PinnedDelegate(fingerprint: fingerprint), delegateQueue: nil)
    }

    /// The raw reply. `path` may carry a query string, which is why the URL is built from a string rather
    /// than `appendingPathComponent`, which would percent-escape the `?`.
    private func callData(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 5) throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: base.absoluteString + path) ?? base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var output: (Int, Data) = (0, Data()); var failure: Error?
        session.dataTask(with: request) { data, response, error in
            failure = error
            output = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure { throw Self.transportError(failure) }
        return output
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) throws -> (Int, [String: Any]) {
        let (status, data) = try callData(method, path, body: body)
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    /// Transport failures are not all the same problem, and the fixes differ: nothing listening means the
    /// helper is not running, while a challenge the pinning delegate cancelled means the certificate on disk
    /// is not the one the running helper is serving (a stale install), which only reinstalling clears.
    static func transportError(_ error: Error) -> Error {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else {
            return BridgeError.message("Could not reach Iris Bridge: \(error.localizedDescription)")
        }
        switch failure.code {
        case NSURLErrorTimedOut:
            return AdminClientError.timedOut
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed:
            return AdminClientError.notRunning
        case NSURLErrorCancelled, NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return AdminClientError.certificateMismatch
        default:
            return BridgeError.message("Could not reach Iris Bridge: \(error.localizedDescription)")
        }
    }

    /// A reply that is not 200 is a failure, never an empty success: `status` printing "?" for every field or
    /// `devices` printing "no paired devices" because the token was wrong would both be lies.
    static func statusError(_ status: Int, _ body: [String: Any], while action: String) -> Error {
        if status == 401 {
            return BridgeError.message("The admin token does not match the running helper. Restart Iris Bridge (run the install command again).")
        }
        let detail = (body["error"] as? String).map { " — \($0)" } ?? ""
        return BridgeError.message("Iris Bridge could not \(action) (HTTP \(status)\(detail)).")
    }

    private func expect200(_ method: String, _ path: String, while action: String) throws -> [String: Any] {
        let (status, body) = try call(method, path)
        guard status == 200 else { throw Self.statusError(status, body, while: action) }
        return body
    }

    public func pairCode() throws -> (code: String, expiresAt: String) {
        let body = try expect200("POST", "/admin/pair-code", while: "create a pairing code")
        guard let code = body["code"] as? String else { throw BridgeError.message("Iris Bridge did not send back a pairing code.") }
        return (code, body["expiresAt"] as? String ?? "")
    }

    public func status() throws -> [String: Any] {
        try expect200("GET", "/status", while: "report its status")
    }

    public func devices() throws -> [[String: Any]] {
        (try expect200("GET", "/admin/devices", while: "list paired devices")["devices"] as? [[String: Any]]) ?? []
    }

    /// `false` only when the helper says there is no such device; every other non-200 throws.
    public func revoke(_ id: String) throws -> Bool {
        let (status, body) = try call("DELETE", "/admin/devices/" + id)
        if status == 404 { return false }
        guard status == 200 else { throw Self.statusError(status, body, while: "revoke that device") }
        return true
    }

    // MARK: - Inbox

    private static func inboxDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 timestamp."))
        }
        return decoder
    }

    /// A 4xx from the inbox is the helper's own sentence about what is wrong with the submission ("Give the
    /// post a title."), and that sentence is what the creator and the agent should both read. Only a reply
    /// with no sentence in it falls back to the generic HTTP wording.
    private static func inboxError(_ status: Int, _ data: Data, while action: String) -> Error {
        let body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        if status >= 400, status < 500, status != 401, let sentence = body["error"] as? String, !sentence.isEmpty {
            return BridgeError.message(sentence)
        }
        return statusError(status, body, while: action)
    }

    public func listSubmissions(status wanted: String) throws -> [Submission] {
        let (status, data) = try callData("GET", "/admin/inbox?status=" + wanted)
        guard status == 200 else { throw Self.inboxError(status, data, while: "list what is waiting") }
        guard let list = try? Self.inboxDecoder().decode([Submission].self, from: data) else {
            throw BridgeError.message("Iris Bridge did not send back a list of submissions.")
        }
        return list
    }

    /// How many decided submissions the helper dropped.
    public func pruneDecided() throws -> Int {
        let body = try expect200("POST", "/admin/inbox/prune", while: "clear decided submissions")
        return body["removed"] as? Int ?? 0
    }

    /// One Iris tool call, answered by the running helper's `ToolService` (contract §8).
    public func callTool(_ body: Data, timeout: TimeInterval) throws -> JSONValue {
        let (status, data) = try callData("POST", "/admin/v3/tool", body: body, timeout: timeout)
        guard status == 200, let result = try? JSONValue.decode(data), result["content"] != nil else {
            throw Self.statusError(status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:], while: "run that tool")
        }
        return result
    }
}
