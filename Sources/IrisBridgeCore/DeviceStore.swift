import Foundation
import CryptoKit
import Security

public struct PairedDevice: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeenAt: Date
}

public final class DeviceStore: @unchecked Sendable {
    public let file: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var devices: [PairedDevice]
    public init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file; self.now = now
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        devices = (try? decoder.decode([PairedDevice].self, from: Data(contentsOf: file))) ?? []
    }
    public var all: [PairedDevice] { lock.lock(); defer { lock.unlock() }; return devices }
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Iris Bridge could not generate a secure random token (\(status)).")
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func issue(name: String, platform: String) throws -> (device: PairedDevice, token: String) {
        lock.lock(); defer { lock.unlock() }
        let token = Self.randomToken()
        let cleanName = String(name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(id: UUID().uuidString.lowercased(), name: cleanName.isEmpty ? "Iris device" : cleanName,
                                  platform: platform == "mac" ? "mac" : "iphone", tokenHash: Self.hash(token), pairedAt: now(), lastSeenAt: now())
        devices.append(device)
        try save()
        return (device, token)
    }
    public func authenticate(token: String) -> PairedDevice? {
        lock.lock(); defer { lock.unlock() }
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { PairingProof.constantTimeEqual($0.tokenHash, hash) }) else { return nil }
        devices[index].lastSeenAt = now()
        try? save()
        return devices[index]
    }
    public func revoke(id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = devices.count
        devices.removeAll { $0.id == id }
        guard devices.count != before else { return false }
        try save(); return true
    }
    private func save() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try BridgePaths.writePrivate(try encoder.encode(devices), to: file)
    }
}
