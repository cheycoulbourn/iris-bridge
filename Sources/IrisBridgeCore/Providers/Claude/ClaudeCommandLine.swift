import Foundation

/// The `claude -p` command line for a chat session (spec §6.4, as the phase 1 spike verified it).
public enum ClaudeCommandLine {
    public static func arguments(binary: String, sessionId: String, resume: Bool, model: String?, effort: String? = nil, mcpConfig: String) -> [String] {
        var arguments = [binary, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages",
                         // Tool search is the one built-in tool: without it every connector's schema goes with every
                         // request, and the owner's 335 tools overflowed Haiku's context (spike Q1).
                         "--tools", "ToolSearch",
                         "--permission-mode", "manual", "--permission-prompts", "host",
                         "--permission-prompt-tool", "mcp__iris__approval",
                         "--mcp-config", mcpConfig,
                         "--append-system-prompt", IrisPrompt.system]
        if let model { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        arguments += resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        return arguments
    }

    /// The per-session MCP config: the helper's own `iris` server, told which thread it serves. A
    /// `--mcp-config` server named `iris` replaces the user-scope registration for the session (spike q1-c).
    public static func mcpConfig(helperBinary: String, threadId: String, root: URL, port: UInt16) -> String {
        let config: JSONValue = ["mcpServers": ["iris": ["type": "stdio", "command": .string(helperBinary),
                                                         "args": ["mcp", "--thread", .string(threadId), "--root", .string(root.path),
                                                                  "--port", .string(String(port))]]]]
        return String(decoding: config.encoded(), as: UTF8.self)
    }
}
