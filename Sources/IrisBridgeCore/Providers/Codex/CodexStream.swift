import Foundation

/// One line of `codex exec --json` output. `thread.started`, `turn.started`, `error` and `turn.failed` are the
/// shapes the phase 1 spike recorded (q4-a). The tool, message and completion events were also recorded on
/// installed Codex 0.159.0 against a synthetic Iris MCP server on first and resumed turns (Fixtures/README.md).
public enum CodexStream {
    public enum Item: Equatable {
        case threadStarted(String)
        case reasoning
        case toolStarted(id: String, server: String, tool: String)
        case toolFinished(id: String, server: String, tool: String, ok: Bool, text: String)
        case message(String)
        case completed(TurnUsage)
        case failed
    }

    public static func items(_ line: Data) -> [Item] {
        guard let event = try? JSONValue.decode(line) else { return [] }
        let item = event["item"]
        switch (event["type"]?.stringValue, item?["type"]?.stringValue) {
        case ("thread.started", _):
            return (event["thread_id"]?.stringValue).map { [.threadStarted($0)] } ?? []
        case ("item.started", "mcp_tool_call"):
            return [.toolStarted(id: item?["id"]?.stringValue ?? "", server: item?["server"]?.stringValue ?? "", tool: item?["tool"]?.stringValue ?? "")]
        case ("item.completed", "mcp_tool_call"):
            let error = item?["error"]?["message"]?.stringValue
            let text = error ?? (item?["result"]?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            return [.toolFinished(id: item?["id"]?.stringValue ?? "", server: item?["server"]?.stringValue ?? "", tool: item?["tool"]?.stringValue ?? "",
                                  ok: item?["status"]?.stringValue == "completed" && error == nil, text: text)]
        case ("item.completed", "agent_message"):
            return (item?["text"]?.stringValue).map { [.message($0)] } ?? []
        case ("item.completed", "reasoning"):
            return [.reasoning]
        case ("turn.completed", _):
            let usage = event["usage"]
            return [.completed(TurnUsage(inputTokens: usage?["input_tokens"]?.intValue ?? 0, outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                                         cacheReadTokens: usage?["cached_input_tokens"]?.intValue ?? 0))]
        case ("turn.failed", _):
            return [.failed]
        default:
            return []
        }
    }
}
