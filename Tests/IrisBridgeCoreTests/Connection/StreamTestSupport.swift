import Foundation
import CryptoKit
@testable import IrisBridgeCore

/// A real helper listener on a free loopback port, TLS and all, for tests that must talk to it the way the
/// app does. Nothing here touches port 48731.
final class LiveTestServer {
    let root: URL
    let devices: DeviceStore
    let hub: StreamHub
    let server: BridgeServer
    let fingerprint: String
    let token: String
    var port: UInt16 { server.actualPort ?? 0 }

    init(helloTimeout: TimeInterval = 10) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = BridgePaths(root: root, logs: root.appendingPathComponent("logs"))
        try paths.prepare()
        let identity = try CertificateManager.load(paths: paths)
        fingerprint = identity.fingerprint
        devices = DeviceStore(file: paths.devices)
        token = try devices.issue(name: "Test phone", platform: "iphone").token
        hub = StreamHub(devices: devices, log: nil, helloTimeout: helloTimeout)
        let router = Router(fingerprint: identity.fingerprint, hostName: "Test Mac", adminToken: String(repeating: "a", count: 40),
                            devices: devices, pairing: PairingCodeStore(), inbox: InboxStore(file: paths.inbox),
                            context: ContextStore(file: paths.context), generator: IdleGenerator(), log: nil)
        server = try BridgeServer(port: 0, identity: identity, router: router, serviceName: "Test Mac", advertise: false, log: nil, streams: hub)
        try server.start()
    }

    deinit { server.stop(); try? FileManager.default.removeItem(at: root) }

    func session() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
    }

    func streamURL() -> URL { URL(string: "wss://127.0.0.1:\(port)/v3/stream")! }
}

/// Trusts exactly one certificate, as the app's pinned session does.
final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        completionHandler(digest == fingerprint ? .useCredential : .cancelAuthenticationChallenge, digest == fingerprint ? URLCredential(trust: trust) : nil)
    }
}

/// A v2 generator for tests that never send `/message`.
final class IdleGenerator: Generator {
    func generate(_ request: MessageRequest) throws -> [String: Any] { throw BridgeError.message("not in this test") }
    func status(_ provider: String) -> ProviderStatus { ProviderStatus(provider: provider, ready: false, message: "Not in this test.") }
    func health(_ provider: String) -> ProviderHealth { ProviderHealth(installed: false, signedIn: false, account: "", cliVersion: "", usage: .unknown) }
    func models(_ provider: String) -> ProviderModelCatalog { ProviderModelCatalog(provider: provider, models: [], source: "unavailable") }
    func cancel(_ id: String) {}
}

/// Receives on a WebSocket task until `count` messages arrived or the task closed.
func receiveMessages(_ task: URLSessionWebSocketTask, count: Int, timeout: TimeInterval = 5) -> [JSONValue] {
    var messages: [JSONValue] = []
    let deadline = Date().addingTimeInterval(timeout)
    while messages.count < count && Date() < deadline {
        let done = DispatchSemaphore(value: 0)
        var received: JSONValue?
        var failed = false
        task.receive { result in
            switch result {
            case .success(.string(let text)): received = try? JSONValue.decode(Data(text.utf8))
            case .success(.data(let data)): received = try? JSONValue.decode(data)
            case .success: break
            case .failure: failed = true
            }
            done.signal()
        }
        if done.wait(timeout: .now() + max(0.1, deadline.timeIntervalSinceNow)) == .timedOut || failed { break }
        if let received { messages.append(received) }
    }
    return messages
}

func sendText(_ task: URLSessionWebSocketTask, _ json: String) {
    let done = DispatchSemaphore(value: 0)
    task.send(.string(json)) { _ in done.signal() }
    _ = done.wait(timeout: .now() + 5)
}

/// Waits until the server closed the task, and returns its close code.
func closeCode(_ task: URLSessionWebSocketTask, timeout: TimeInterval = 5) -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while task.closeCode == .invalid && Date() < deadline {
        _ = receiveMessages(task, count: 1, timeout: 0.3)
    }
    return task.closeCode.rawValue
}
