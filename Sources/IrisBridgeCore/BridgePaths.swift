import Foundation

public struct BridgePaths: Sendable {
    public var root: URL
    public var logs: URL
    public init(root: URL, logs: URL) { self.root = root; self.logs = logs }
    public static var standard: BridgePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return BridgePaths(root: home.appendingPathComponent("Library/Application Support/Iris Bridge"),
                           logs: home.appendingPathComponent("Library/Logs/Iris Bridge"))
    }
    public var certificate: URL { root.appendingPathComponent("certificate.pem") }
    public var privateKey: URL { root.appendingPathComponent("private-key.pem") }
    public var identity: URL { root.appendingPathComponent("identity.p12") }
    public var identityPassphrase: URL { root.appendingPathComponent("identity-passphrase") }
    public var adminToken: URL { root.appendingPathComponent("admin-token") }
    public var devices: URL { root.appendingPathComponent("devices.json") }
    public var logFile: URL { logs.appendingPathComponent("bridge.log") }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        // Left over from the Python helper; its single shared token is no longer honored.
        try? fm.removeItem(at: root.appendingPathComponent("pairing-token"))
        try? fm.removeItem(at: root.appendingPathComponent("Connect Iris.txt"))
    }
    public static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
