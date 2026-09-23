import Foundation

/// What `iris-bridge status` prints, from the helper's own `/status` reply. A pure function, so the wording is
/// tested without a running helper; a 0.2.4 helper's reply (no `health`) still prints its first lines.
public enum StatusReport {
    public static func lines(status: [String: Any], port: UInt16, pairedDevices: Int, addresses: [String],
                             now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        let providers = status["providers"] as? [String: [String: Any]] ?? [:]
        let health = status["health"] as? [String: [String: Any]] ?? [:]
        var lines = ["Iris Bridge \(status["helperVersion"] as? String ?? "?") on \(status["hostName"] as? String ?? "?") (port \(port))"]
        for name in ["claude", "codex"] {
            let ready = providers[name]?["ready"] as? Bool == true
            var line = "  \(name): \(ready ? "signed in" : "not signed in") — \(providers[name]?["message"] as? String ?? "")"
            if let entry = health[name] {
                let version = entry["cliVersion"] as? String ?? ""
                if !version.isEmpty { line += " — CLI \(version)" }
                let usage = entry["usage"] as? String
                if usage == "limited" {
                    if let reset = (entry["resetsAt"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                        line += " — usage limit until \(ProviderFailure.clock(reset, now: now, timeZone: timeZone))"
                    } else {
                        line += " — usage limit reached"
                    }
                } else {
                    if usage == "ok" { line += " — usage ok" }
                    if let cause = entry["lastErrorCause"] as? String { line += " — last turn failed: \(cause)" }
                }
            }
            lines.append(line)
        }
        lines.append("  paired devices: \(pairedDevices)")
        if !addresses.isEmpty { lines.append("  reach this Mac at: \(addresses.joined(separator: ", "))") }
        return lines
    }
}
