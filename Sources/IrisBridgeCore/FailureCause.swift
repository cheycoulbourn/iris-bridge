import Foundation

/// Why a request failed, from the fixed list the app puts a label on (spec §6.4 and §9.2). The raw value is
/// the wire name every error body carries in `cause`. Older apps ignore the field and keep reading `error`.
public enum FailureCause: String, CaseIterable, Sendable {
    case signedOut, usageLimit, providerUnavailable, modelUnavailable, timeout, cancelled, busy, deviceRevoked, badRequest
    case `internal`

    /// The cause for an error response whose code named none. The router's own refusals (a body it cannot
    /// read, an unknown route, the one-message-at-a-time lock) already say what went wrong through their status.
    public static func forStatus(_ status: Int) -> FailureCause {
        switch status {
        case 401: return .deviceRevoked
        case 409, 429: return .busy
        case 504: return .timeout
        case 400..<500: return .badRequest
        default: return .internal
        }
    }
}

/// A provider turn that produced no reply. `details` keeps the provider's own words (I1). `message`, when set,
/// replaces the sentence the cause would produce, for the few failures the helper words itself.
public struct ProviderFailure: Error, Equatable {
    /// The longest `details` the wire carries (contract §1).
    public static let detailLimit = 2_000

    public var cause: FailureCause
    public var provider: String
    public var details: String?
    public var resetsAt: Date?
    public var message: String?

    public init(cause: FailureCause, provider: String, details: String? = nil, resetsAt: Date? = nil, message: String? = nil) {
        self.cause = cause
        self.provider = provider
        let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.details = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.detailLimit))
        self.resetsAt = resetsAt
        self.message = message
    }

    /// The status v0.2.4 answered the same failure with: 504 for a timeout, 502 for everything else a provider
    /// run can end in. Older apps branch on these, so they do not move.
    public var httpStatus: Int { cause == .timeout ? 504 : 502 }

    /// The `error` sentence: the cause and one next step, in words an older app can show as they stand.
    public func sentence(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        if let message { return message }
        let name = provider == "claude" ? "Claude" : "ChatGPT"
        switch cause {
        case .signedOut:
            return provider == "claude"
                ? "Claude is signed out on your Mac. On the Mac, open Terminal and run `claude auth login`."
                : "ChatGPT is signed out on your Mac. On the Mac, open Terminal and run `codex login`."
        case .usageLimit:
            guard let resetsAt else { return "\(name)'s usage limit is reached. Try again later." }
            return "\(name)'s usage limit is reached until \(Self.clock(resetsAt, now: now, timeZone: timeZone))."
        case .providerUnavailable:
            return "\(name) could not be reached from your Mac. Check the Mac's internet connection, then try again."
        case .modelUnavailable:
            return "That model isn't available on your plan. Pick another model."
        case .timeout:
            return BridgeError.timeout.errorDescription ?? "Your provider took too long."
        case .cancelled:
            return BridgeError.canceled.errorDescription ?? "Request canceled."
        case .busy:
            return "Iris is still answering another message. Try again when it finishes."
        case .deviceRevoked:
            return "This device isn't paired with your Mac."
        case .badRequest:
            return "Iris Bridge could not read that request."
        case .internal:
            let tool = provider == "claude" ? "Claude Code" : "Codex"
            guard let details else { return "\(tool) could not finish. Nothing was changed." }
            return "\(tool) could not finish. Nothing was changed. It said: \(OneLineText.clean(details, limit: 200))"
        }
    }

    /// The whole error body (contract §1): the sentence older apps read, plus the fields newer apps label.
    public func body(now: Date = Date(), timeZone: TimeZone = .current) -> [String: Any] {
        var body: [String: Any] = ["error": sentence(now: now, timeZone: timeZone), "cause": cause.rawValue, "provider": provider]
        if let details { body["details"] = details }
        if let resetsAt { body["resetsAt"] = ISO8601DateFormatter().string(from: resetsAt) }
        return body
    }

    /// "4:00 PM" when the time is later today, "Sep 26, 8:41 AM" otherwise, on the Mac's own clock.
    static func clock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

extension ProviderFailure: LocalizedError {
    public var errorDescription: String? { sentence() }
}
