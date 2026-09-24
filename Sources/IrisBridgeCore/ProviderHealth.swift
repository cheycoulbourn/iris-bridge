import Foundation

/// One provider as the app's health card shows it (contract §2): installed, signed in, on which plan, with
/// which CLI version, and what the last turn said about usage.
public struct ProviderHealth: Equatable, Sendable {
    public enum Usage: String, Sendable { case ok, limited, unknown }

    public var installed: Bool
    public var signedIn: Bool
    /// The plan label ("Max", "Pro"), or empty when the provider does not say or nobody is signed in.
    public var account: String
    /// The CLI's version ("2.1.274", "0.155.0-alpha.9.2"), or empty when it could not be read.
    public var cliVersion: String
    public var usage: Usage
    public var resetsAt: Date?
    public var lastErrorCause: FailureCause?
    /// False when the sign-in check did not finish (a busy Mac). `signedIn` then says whether the helper still
    /// tries a turn: true when this Mac confirmed a subscription sign-in earlier, false when nothing has ruled out
    /// an API key yet.
    public var signInChecked: Bool

    public init(installed: Bool, signedIn: Bool, account: String, cliVersion: String, usage: Usage,
                resetsAt: Date? = nil, lastErrorCause: FailureCause? = nil, signInChecked: Bool = true) {
        self.installed = installed; self.signedIn = signedIn; self.account = account; self.cliVersion = cliVersion
        self.usage = usage; self.resetsAt = resetsAt; self.lastErrorCause = lastErrorCause; self.signInChecked = signInChecked
    }

    /// The wire shape. A reset or a cause nobody reported is absent, not null, and `signInChecked` is sent only
    /// when it is false, so a finished check sends exactly what 0.2.5 sent.
    public var json: [String: Any] {
        var body: [String: Any] = ["installed": installed, "signedIn": signedIn, "account": account,
                                   "cliVersion": cliVersion, "usage": usage.rawValue]
        if let resetsAt { body["resetsAt"] = ISO8601DateFormatter().string(from: resetsAt) }
        if let lastErrorCause { body["lastErrorCause"] = lastErrorCause.rawValue }
        if !signInChecked { body["signInChecked"] = false }
        return body
    }

    /// The version in a CLI's `--version` line: "2.1.274 (Claude Code)" → "2.1.274",
    /// "codex-cli 0.155.0-alpha.9.2" → "0.155.0-alpha.9.2". Empty when there is none.
    public static func version(from output: String) -> String {
        guard let range = output.range(of: #"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?"#, options: .regularExpression) else { return "" }
        return String(output[range])
    }
}

/// What the last turn for each provider said about usage (contract §4). A usage-limit failure is remembered
/// until the reset the provider named, or for six hours when it named none; the next successful turn clears
/// it. Held in memory only: after a restart the helper honestly knows nothing until the next turn.
public final class UsageMemory: @unchecked Sendable {
    public static let assumedLimit: TimeInterval = 6 * 60 * 60

    private struct Entry {
        var usage: ProviderHealth.Usage = .unknown
        var limitedUntil: Date?
        var resetsAt: Date?
        var lastErrorCause: FailureCause?
    }

    private let lock = NSLock()
    private let now: () -> Date
    private var entries: [String: Entry] = [:]

    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func recordSuccess(_ provider: String) {
        lock.lock(); defer { lock.unlock() }
        entries[provider] = Entry(usage: .ok)
    }

    /// A cancelled turn says nothing about the provider, so it is not remembered.
    public func recordFailure(_ failure: ProviderFailure) {
        guard failure.cause != .cancelled else { return }
        lock.lock(); defer { lock.unlock() }
        var entry = entries[failure.provider] ?? Entry()
        entry.lastErrorCause = failure.cause
        if failure.cause == .usageLimit {
            entry.usage = .limited
            entry.resetsAt = failure.resetsAt
            entry.limitedUntil = failure.resetsAt ?? now().addingTimeInterval(Self.assumedLimit)
        }
        entries[failure.provider] = entry
    }

    public func current(_ provider: String) -> (usage: ProviderHealth.Usage, resetsAt: Date?, lastErrorCause: FailureCause?) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[provider] else { return (.unknown, nil, nil) }
        if entry.usage == .limited, let until = entry.limitedUntil, until <= now() {
            entry.usage = .unknown; entry.limitedUntil = nil; entry.resetsAt = nil
            entries[provider] = entry
        }
        return (entry.usage, entry.resetsAt, entry.lastErrorCause)
    }
}
