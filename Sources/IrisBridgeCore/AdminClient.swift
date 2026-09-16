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

/// Nothing is listening on the loopback port, or nothing is installed to listen with. Typed rather than a
/// sentence because two callers word it differently: Terminal tells you how to start the helper, an MCP tool
/// tells the agent to check `iris-bridge status`.
public enum AdminClientError: Error, Equatable, LocalizedError {
    case notRunning
    public var errorDescription: String? {
        "Iris Bridge is not running on this Mac. Run the install command again to start it."
    }
}

/// What the MCP server needs from the running helper. A protocol so the tools can be tested without a
/// listening socket — including the case where there is deliberately nothing to listen to.
public protocol AdminClientProtocol: AnyObject {
    func submit(kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?,
                agent: String, note: String?, revisionOf: String?) throws -> Submission
    func listSubmissions(status: String) throws -> [Submission]
    func context() throws -> WorkspaceContext
}

public final class AdminClient {
    private let base: URL
    private let token: String
    private let session: URLSession
    public init(paths: BridgePaths, port: UInt16) throws {
        let pem = try String(contentsOf: paths.certificate, encoding: .utf8)
        token = try String(contentsOf: paths.adminToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        base = URL(string: "https://127.0.0.1:\(port)")!
        session = URLSession(configuration: .ephemeral, delegate: PinnedDelegate(fingerprint: try CertificateManager.fingerprint(pem: pem)), delegateQueue: nil)
    }

    /// The raw reply. `path` may carry a query string, which is why the URL is built from a string rather
    /// than `appendingPathComponent`, which would percent-escape the `?`.
    private func callData(_ method: String, _ path: String, body: Data? = nil) throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: base.absoluteString + path) ?? base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 5
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
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed:
            return AdminClientError.notRunning
        case NSURLErrorCancelled, NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return BridgeError.message("Iris Bridge's certificate does not match. Run `iris-bridge uninstall`, then install again.")
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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
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

    public func submit(kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?,
                       agent: String, note: String?, revisionOf: String?) throws -> Submission {
        struct Body: Encodable {
            var kind: SubmissionKind; var post: SubmittedPost?; var series: SubmittedSeries?
            var agent: String; var note: String?; var revisionOf: String?
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Body(kind: kind, post: post, series: series, agent: agent, note: note, revisionOf: revisionOf))
        let (status, data) = try callData("POST", "/admin/inbox", body: body)
        guard status == 200 else { throw Self.inboxError(status, data, while: "accept that submission") }
        guard let submission = try? Self.inboxDecoder().decode(Submission.self, from: data) else {
            throw BridgeError.message("Iris Bridge did not send back the submission it saved.")
        }
        return submission
    }

    public func listSubmissions(status wanted: String) throws -> [Submission] {
        let (status, data) = try callData("GET", "/admin/inbox?status=" + wanted)
        guard status == 200 else { throw Self.inboxError(status, data, while: "list what is waiting") }
        guard let list = try? Self.inboxDecoder().decode([Submission].self, from: data) else {
            throw BridgeError.message("Iris Bridge did not send back a list of submissions.")
        }
        return list
    }

    public func context() throws -> WorkspaceContext {
        let (status, data) = try callData("GET", "/admin/context")
        guard status == 200 else { throw Self.inboxError(status, data, while: "describe the workspace") }
        guard let context = try? Self.inboxDecoder().decode(WorkspaceContext.self, from: data) else {
            throw BridgeError.message("Iris Bridge did not send back a workspace snapshot.")
        }
        return context
    }

    /// How many decided submissions the helper dropped.
    public func pruneDecided() throws -> Int {
        let body = try expect200("POST", "/admin/inbox/prune", while: "clear decided submissions")
        return body["removed"] as? Int ?? 0
    }
}

extension AdminClient: AdminClientProtocol {}

/// The MCP server's way in. It builds an `AdminClient` per call rather than holding one, because the helper
/// can be installed, started or restarted while Claude Code keeps the same MCP process alive for hours: a
/// client captured at launch would keep reporting a Mac that has since come back.
public final class LoopbackAdminClient: AdminClientProtocol {
    private let paths: BridgePaths
    private let port: UInt16
    public init(paths: BridgePaths, port: UInt16) { self.paths = paths; self.port = port }

    /// No certificate and no admin token on disk means nothing has ever run here, which the agent should
    /// hear as "not running" rather than as a missing file it cannot do anything about.
    private func client() throws -> AdminClient {
        do { return try AdminClient(paths: paths, port: port) } catch { throw AdminClientError.notRunning }
    }

    public func submit(kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?,
                       agent: String, note: String?, revisionOf: String?) throws -> Submission {
        try client().submit(kind: kind, post: post, series: series, agent: agent, note: note, revisionOf: revisionOf)
    }
    public func listSubmissions(status: String) throws -> [Submission] { try client().listSubmissions(status: status) }
    public func context() throws -> WorkspaceContext { try client().context() }
}
