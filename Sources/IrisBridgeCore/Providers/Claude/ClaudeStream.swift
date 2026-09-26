import Foundation

/// One line of `claude -p --output-format stream-json --include-partial-messages` output, read for what the
/// helper acts on. Shapes are the ones the phase 1 spike recorded from Claude Code 2.1.274. Full `assistant`
/// messages repeat text the deltas already carried, so only their `tool_use` blocks are read (spike Q3).
public enum ClaudeStream {
    public enum Item: Equatable {
        case controlResponse(id: String, ok: Bool, response: JSONValue)
        case initialized(model: String?, apiKeySource: String?)
        case thinking
        case text(String)
        case toolUse(id: String, name: String)
        case toolResult(id: String, isError: Bool, text: String)
        case rateLimit(limited: Bool, resetsAt: Date?)
        case result(JSONValue)
    }

    public static func items(_ line: Data) -> [Item] {
        guard let event = try? JSONValue.decode(line) else { return [] }
        switch event["type"]?.stringValue {
        case "control_response":
            guard let response = event["response"], let id = response["request_id"]?.stringValue else { return [] }
            return [.controlResponse(id: id, ok: response["subtype"]?.stringValue == "success", response: response["response"] ?? .null)]
        case "system":
            guard event["subtype"]?.stringValue == "init" else { return [] }
            return [.initialized(model: event["model"]?.stringValue, apiKeySource: event["apiKeySource"]?.stringValue)]
        case "stream_event":
            let inner = event["event"]
            switch inner?["type"]?.stringValue {
            case "content_block_start" where inner?["content_block"]?["type"]?.stringValue == "thinking":
                return [.thinking]
            case "content_block_delta" where inner?["delta"]?["type"]?.stringValue == "text_delta":
                return (inner?["delta"]?["text"]?.stringValue).map { [.text($0)] } ?? []
            default:
                return []
            }
        case "assistant":
            return (event["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
                return .toolUse(id: id, name: name)
            }
        case "user":
            return (event["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                let content = block["content"]
                let text = content?.stringValue ?? (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                return .toolResult(id: id, isError: block["is_error"]?.boolValue ?? false, text: text)
            }
        case "rate_limit_event":
            let info = event["rate_limit_info"]
            let resets = info?["resetsAt"]?.numberValue.map { Date(timeIntervalSince1970: $0) }
            return [.rateLimit(limited: info?["status"]?.stringValue == "rejected", resetsAt: resets)]
        case "result":
            return [.result(event)]
        default:
            return []
        }
    }
}
