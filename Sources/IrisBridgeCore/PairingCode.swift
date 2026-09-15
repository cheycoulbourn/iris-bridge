import Foundation
import CryptoKit

public enum PairingProof {
    public static func compute(code: String, fingerprint: String) -> String {
        let key = SymmetricKey(data: Data(code.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(fingerprint.lowercased().utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

public enum PairingResult: Equatable { case accepted, wrongCode(attemptsLeft: Int), expired, noCode }

public final class PairingCodeStore: @unchecked Sendable {
    public static let lifetime: TimeInterval = 600
    public static let maxAttempts = 5
    private struct Active { var code: String; var expiresAt: Date; var attemptsLeft: Int }
    private var active: Active?
    private let lock = NSLock()
    private let now: () -> Date
    private let generator: () -> String
    public init(now: @escaping () -> Date = Date.init, generator: @escaping () -> String = PairingCodeStore.randomCode) {
        self.now = now; self.generator = generator
    }
    public static func randomCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }
    public func issue() -> (code: String, expiresAt: Date) {
        lock.lock(); defer { lock.unlock() }
        let code = generator(); let expires = now().addingTimeInterval(Self.lifetime)
        active = Active(code: code, expiresAt: expires, attemptsLeft: Self.maxAttempts)
        return (code, expires)
    }
    public func redeem(proof: String, fingerprint: String) -> PairingResult {
        lock.lock(); defer { lock.unlock() }
        guard var current = active else { return .noCode }
        if now() > current.expiresAt { active = nil; return .expired }
        let expected = PairingProof.compute(code: current.code, fingerprint: fingerprint)
        if PairingProof.constantTimeEqual(expected, proof.lowercased()) { active = nil; return .accepted }
        current.attemptsLeft -= 1
        active = current.attemptsLeft > 0 ? current : nil
        return .wrongCode(attemptsLeft: current.attemptsLeft)
    }
}

public final class RateLimiter: @unchecked Sendable {
    private let limit: Int; private let window: TimeInterval; private let now: () -> Date
    private var hits: [String: [Date]] = [:]
    private let lock = NSLock()
    public init(limit: Int, per seconds: TimeInterval, now: @escaping () -> Date = Date.init) { self.limit = limit; window = seconds; self.now = now }
    public func allow(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        var recent = (hits[key] ?? []).filter { t.timeIntervalSince($0) < window }
        guard recent.count < limit else { hits[key] = recent; return false }
        recent.append(t); hits[key] = recent; return true
    }
}
