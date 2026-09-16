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

    private func call(_ method: String, _ path: String) throws -> (Int, [String: Any]) {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = method; request.timeoutInterval = 5
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var output: (Int, [String: Any]) = (0, [:]); var failure: Error?
        session.dataTask(with: request) { data, response, error in
            failure = error
            output = ((response as? HTTPURLResponse)?.statusCode ?? 0, (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:])
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure { throw Self.transportError(failure) }
        return output
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
            return BridgeError.message("Iris Bridge is not running on this Mac. Run the install command again to start it.")
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
}
