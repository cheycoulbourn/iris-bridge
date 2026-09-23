import Foundation

/// What a provider CLI printed for one turn, read the way a person would: its own JSON events first, then its
/// stderr, then any loose lines on stdout. A failed turn comes out as one `ProviderFailure` with a cause from
/// the fixed list (spec §6.4) and the provider's own words in `details` (I1). Nothing here runs a process, so
/// every case is tested against recorded output in Tests/IrisBridgeCoreTests/Fixtures.
public enum ProviderOutput {
    /// One JSON object per stdout line. Anything else on stdout is not an event and is skipped.
    public static func events(_ stdout: String) -> [[String: Any]] {
        stdout.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    /// A `claude -p --output-format stream-json` turn that did not end in a successful `result`. Claude Code
    /// marks an API failure on the assistant message (`error`: `authentication_failed`, `rate_limit`,
    /// `billing_error`, `server_error`, `invalid_request`, `unknown`) and repeats its text in `result`.
    public static func claudeFailure(_ result: ProcessResult, now: Date = Date(), timeZone: TimeZone = .current) -> ProviderFailure {
        let events = Self.events(result.stdout)
        let end = events.last { $0["type"] as? String == "result" }
        let assistant = events.last { $0["type"] as? String == "assistant" && $0["error"] is String }
        let content = (assistant?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let assistantText = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let resultText = end?["result"] as? String ?? ""
        let said = resultText.isEmpty ? assistantText : resultText
        let stderr = tail(result.stderr)
        let fromText = classify(said + "\n" + stderr)
        let cause: FailureCause
        switch assistant?["error"] as? String ?? "" {
        case "authentication_failed": cause = .signedOut
        case "rate_limit", "billing_error": cause = fromText == .modelUnavailable ? .modelUnavailable : .usageLimit
        case "server_error": cause = .providerUnavailable
        default: cause = fromText
        }
        let details = [said, stderr, loose(result.stdout), end?["subtype"] as? String ?? ""].first { !$0.isEmpty }
            ?? "Claude Code exited with status \(result.status) and printed no reason."
        return ProviderFailure(cause: cause, provider: "claude", details: details,
                               resetsAt: cause == .usageLimit ? claudeReset(in: said, now: now, timeZone: timeZone) : nil)
    }

    /// A `codex exec --json` turn that did not reach `turn.completed`. Codex reports the failure twice, as an
    /// `error` event and as `turn.failed`'s `error.message`; either is the provider's own sentence. Non-fatal
    /// warnings arrive as `item.completed` items of type `error` and are not the reason a turn failed.
    public static func codexFailure(_ result: ProcessResult, timeZone: TimeZone = .current) -> ProviderFailure {
        let events = Self.events(result.stdout)
        let failedEvent = events.last { $0["type"] as? String == "turn.failed" }
        let errorEvent = events.last { $0["type"] as? String == "error" }
        let said = ((failedEvent?["error"] as? [String: Any])?["message"] as? String) ?? (errorEvent?["message"] as? String) ?? ""
        let stderr = tail(result.stderr)
        let cause = classify(said + "\n" + stderr)
        let details = [said, stderr, loose(result.stdout)].first { !$0.isEmpty }
            ?? "Codex exited with status \(result.status) and printed no reason."
        return ProviderFailure(cause: cause, provider: "codex", details: details,
                               resetsAt: cause == .usageLimit ? codexReset(in: said, timeZone: timeZone) : nil)
    }

    /// The cause a provider's own words point to, most specific first: a model message can mention credits,
    /// and a usage-limit message can mention buying more.
    static func classify(_ text: String) -> FailureCause {
        let said = text.lowercased()
        func mentions(_ phrases: [String]) -> Bool { phrases.contains { said.contains($0) } }
        if said.contains("model"), mentions(["not supported", "not available", "does not exist", "not found", "unsupported",
                                               "do not have access", "don't have access", "issue with the selected model",
                                               "requires usage credits"]) { return .modelUnavailable }
        if mentions(["usage limit", "session limit", "weekly limit", "limit reached", "hit your limit", "rate limit",
                     "rate_limit", "quota", "too many requests", "out of credits", "purchase more credits"]) { return .usageLimit }
        if mentions(["not logged in", "please log in", "log in again", "sign in again", "run /login",
                     "failed to authenticate", "authentication_error", "authentication failed", "unauthorized",
                     "invalid api key", "oauth", "refresh token", "token expired", "token has expired"]) { return .signedOut }
        if mentions(["overloaded", "service unavailable", "bad gateway", "internal server error", "stream disconnected",
                     "error sending request", "can't reach", "cannot reach", "connection refused", "connection reset",
                     "network error", "enotfound", "econnrefused", "econnreset", "etimedout", "fetch failed",
                     "unable to connect", "went to sleep"]) { return .providerUnavailable }
        return .internal
    }

    /// "resets 7:20pm (America/New_York)": the next time the clock reads that, in the zone Claude names (the
    /// Mac's own when it names none).
    static func claudeReset(in text: String, now: Date, timeZone: TimeZone) -> Date? {
        guard let parts = match(#"resets (\d{1,2})(?::(\d{2}))? ?([ap]m)(?: \(([^)]+)\))?"#, in: text),
              let hour = Int(parts[1]) else { return nil }
        let zone = TimeZone(identifier: parts[4]) ?? timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year, let month = today.month, let day = today.day,
              let candidate = clockTime(year: year, month: month, day: day, hour: hour, minute: Int(parts[2]) ?? 0,
                                        pm: parts[3].lowercased() == "pm", timeZone: zone) else { return nil }
        return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    /// "try again at Sep 26th, 2026 8:41 AM." Codex prints the reset on the Mac's own clock.
    static func codexReset(in text: String, timeZone: TimeZone) -> Date? {
        guard let parts = match(#"try again at ([a-z]{3})[a-z]* (\d{1,2})(?:st|nd|rd|th)?,? (\d{4}),? (\d{1,2}):(\d{2}) ?([ap]m)"#, in: text),
              let month = months.firstIndex(of: parts[1].lowercased()),
              let day = Int(parts[2]), let year = Int(parts[3]), let hour = Int(parts[4]), let minute = Int(parts[5]) else { return nil }
        return clockTime(year: year, month: month + 1, day: day, hour: hour, minute: minute, pm: parts[6].lowercased() == "pm", timeZone: timeZone)
    }

    /// The last `ProviderFailure.detailLimit` characters: the end of a stderr dump is where the reason is.
    static func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= ProviderFailure.detailLimit ? trimmed : String(trimmed.suffix(ProviderFailure.detailLimit))
    }

    /// Stdout lines that are not JSON events. A CLI that fails before its event stream starts says why here.
    static func loose(_ stdout: String) -> String {
        tail(stdout.split(separator: "\n").filter { !$0.hasPrefix("{") }.joined(separator: "\n"))
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func clockTime(year: Int, month: Int, day: Int, hour: Int, minute: Int, pm: Bool, timeZone: TimeZone) -> Date? {
        guard (1...12).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour % 12 + (pm ? 12 : 0), minute: minute))
    }

    /// Every capture group of the first case-insensitive match, "" for a group that did not take part.
    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
