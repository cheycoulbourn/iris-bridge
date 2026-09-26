import Foundation

/// The `codex exec` command lines (spec §6.4). The first-turn flags are the ones the phase 1 spike verified on
/// Codex 0.155.0-alpha.9.2 (q4-a): only the Iris server loads, the owner's own Codex config stays unloaded, and
/// no `--disable` name is refused. The `exec resume` flags come from its `--help`; resume, tool calls and their
/// events are unverified until the spike's Codex retry (S7) runs.
public enum CodexCommandLine {
    /// Everything but the shell, the web and the owner's own setup.
    static let disabledFeatures = ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use", "code_mode", "hooks", "plugins", "memories"]

    public static func arguments(binary: String, resume sessionId: String?, model: String?, effort: String? = nil, helperBinary: String, threadId: String,
                                 root: URL, port: UInt16, images: [String]) -> [String] {
        var arguments = [binary, "exec"]
        if let sessionId {
            // `exec resume` has no `--sandbox` flag; the same setting goes in as config.
            arguments += ["resume", sessionId, "--json", "--ignore-user-config", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\""]
        } else {
            arguments += ["--json", "--ignore-user-config", "--skip-git-repo-check", "--sandbox", "read-only"]
        }
        arguments += ["-c", "web_search=\"disabled\"",
                      // Passed on every run: a per-run server is not remembered by a resumed session.
                      "-c", "mcp_servers.iris.command=\(toml(helperBinary))",
                      "-c", "mcp_servers.iris.args=[\(["mcp", "--thread", threadId, "--root", root.path, "--port", String(port)].map(toml).joined(separator: ","))]"]
        for feature in disabledFeatures { arguments += ["--disable", feature] }
        if let model { arguments += ["-c", "model=\(toml(model))"] }
        // Codex documents `model_reasoning_effort` as low/medium/high; the app's xhigh and max (Claude-only
        // levels) map down to Codex's highest rather than being refused.
        if let effort { arguments += ["-c", "model_reasoning_effort=\(toml(codexEffort(effort)))"] }
        for image in images { arguments += ["-i", image] }
        // `--ephemeral` is never passed: an ephemeral session cannot be resumed.
        return arguments + ["-"]
    }

    /// Maps the app's five-level effort vocabulary onto Codex's documented `model_reasoning_effort` values
    /// (low/medium/high): xhigh and max, which only Claude offers, fold into Codex's highest, high.
    static func codexEffort(_ effort: String) -> String {
        switch effort {
        case "xhigh", "max": return "high"
        default: return effort
        }
    }

    /// A TOML basic string.
    static func toml(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
