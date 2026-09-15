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
        if failure != nil { throw BridgeError.message("Iris Bridge is not running. Run the install command again to start it.") }
        return output
    }
    public func pairCode() throws -> (code: String, expiresAt: String) {
        let (status, body) = try call("POST", "/admin/pair-code")
        guard status == 200, let code = body["code"] as? String else { throw BridgeError.message("Could not create a pairing code (\(status)).") }
        return (code, body["expiresAt"] as? String ?? "")
    }
    public func status() throws -> [String: Any] { try call("GET", "/status").1 }
    public func devices() throws -> [[String: Any]] { (try call("GET", "/admin/devices").1["devices"] as? [[String: Any]]) ?? [] }
    public func revoke(_ id: String) throws -> Bool { try call("DELETE", "/admin/devices/" + id).0 == 200 }
}
