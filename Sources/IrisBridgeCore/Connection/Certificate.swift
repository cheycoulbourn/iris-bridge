import Foundation
import Security
import CryptoKit

public struct BridgeIdentity {
    public let fingerprint: String
    public let secIdentity: SecIdentity
    public let certificatePEM: String
}

public enum CertificateError: LocalizedError {
    case openssl(String), unreadable, importFailed(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .openssl(let m): return "Could not create the bridge certificate: \(m)"
        case .unreadable: return "The bridge certificate is unreadable. Run iris-bridge uninstall, then install again."
        case .importFailed(let s): return "Could not load the bridge identity (\(s))."
        }
    }
}

public enum CertificateManager {
    public static func load(paths: BridgePaths) throws -> BridgeIdentity {
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.certificate.path) || !fm.fileExists(atPath: paths.privateKey.path) {
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", paths.privateKey.path, "-out", paths.certificate.path,
                         "-days", "3650", "-subj", "/CN=Iris Local Bridge"])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.privateKey.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.certificate.path)
            try? fm.removeItem(at: paths.identity)
        }
        if !fm.fileExists(atPath: paths.identity.path) {
            let passphrase = DeviceStore.randomToken()
            try BridgePaths.writePrivate(Data(passphrase.utf8), to: paths.identityPassphrase)
            try openssl(["pkcs12", "-export", "-inkey", paths.privateKey.path, "-in", paths.certificate.path, "-out", paths.identity.path,
                         "-passout", "pass:" + passphrase])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.identity.path)
        }
        let pem = try String(contentsOf: paths.certificate, encoding: .utf8)
        let passphrase = try String(contentsOf: paths.identityPassphrase, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let p12 = try Data(contentsOf: paths.identity)
        let options: [CFString: Any] = [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true]
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw CertificateError.importFailed(status) }
        return BridgeIdentity(fingerprint: try fingerprint(pem: pem), secIdentity: identity as! SecIdentity, certificatePEM: pem)
    }

    public static func fingerprint(pem: String) throws -> String {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        guard let der = Data(base64Encoded: body) else { throw CertificateError.unreadable }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func openssl(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = args
        let err = Pipe(); process.standardError = err; process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CertificateError.openssl(String(text.prefix(200)))
        }
    }
}
