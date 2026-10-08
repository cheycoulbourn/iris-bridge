import Foundation
import Security
import CoreImage

public struct PairingQRPayload: Codable, Equatable {
    public var version: Int = 1
    public var url: String
    public var fingerprint: String
    public var secret: String
    public var hostName: String
    public var expiresAt: String

    public var encodedString: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(self)
        return "iris-pair:" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum QRPairingResult: Equatable { case accepted, invalid, expired, unavailable }

/// QR secrets stay only in memory, expire in ten minutes, and are consumed atomically. A newly issued QR
/// replaces the previous QR; manual pairing codes have an independent lifetime for older apps.
public final class PairingQRStore: @unchecked Sendable {
    public static let lifetime: TimeInterval = 600
    private struct Active { let secret: String; let fingerprint: String; let expiresAt: Date }
    private let lock = NSLock()
    private let now: () -> Date
    private var active: Active?
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func issue(url: String, fingerprint: String, hostName: String) -> PairingQRPayload {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "Could not generate a pairing secret.")
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        let expires = now().addingTimeInterval(Self.lifetime)
        active = Active(secret: secret, fingerprint: fingerprint.lowercased(), expiresAt: expires)
        return PairingQRPayload(url: url, fingerprint: fingerprint.lowercased(), secret: secret, hostName: hostName,
                                expiresAt: ISO8601DateFormatter().string(from: expires))
    }

    public func redeem(proof: String, fingerprint: String) -> QRPairingResult {
        lock.lock(); defer { lock.unlock() }
        guard let current = active else { return .unavailable }
        guard now() < current.expiresAt else { active = nil; return .expired }
        guard PairingProof.constantTimeEqual(current.fingerprint, fingerprint.lowercased()),
              PairingProof.constantTimeEqual(PairingProof.compute(code: current.secret, fingerprint: fingerprint), proof.lowercased()) else { return .invalid }
        active = nil
        return .accepted
    }
}

/// CoreImage supplies the QR modules; ANSI black-on-white half blocks keep each module square on a
/// standard Terminal font. The four-module white quiet zone is included on every side.
public enum TerminalPairingQR {
    public static func render(_ payload: PairingQRPayload) throws -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw BridgeError.message("Could not create the pairing QR code.") }
        filter.setValue(Data(payload.encodedString.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw BridgeError.message("Could not create the pairing QR code.") }
        let size = Int(image.extent.width)
        var pixels = [UInt8](repeating: 0, count: size * size)
        CIContext().render(image, toBitmap: &pixels, rowBytes: size, bounds: image.extent, format: .L8, colorSpace: nil)
        let quiet = 4, width = size + quiet * 2
        func black(_ x: Int, _ y: Int) -> Bool {
            guard x >= quiet, y >= quiet, x < size + quiet, y < size + quiet else { return false }
            return pixels[(y - quiet) * size + x - quiet] < 128
        }
        var lines: [String] = []
        for y in stride(from: 0, to: width, by: 2) {
            var line = "\u{001B}[30;47m"
            for x in 0..<width {
                switch (black(x, y), black(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{001B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
