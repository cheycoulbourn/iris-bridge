import Foundation

/// What a tool a chat session wants to use is, for the approval rules (spec §6.5).
public enum ToolClass: Equatable {
    case iris
    case toolSearch
    case connectorRead(ConnectorTable.Connector, tool: String)
    case connectorWrite(ConnectorTable.Connector, tool: String)
    /// Anything else: the Mac's own MCP servers, plugin servers, or a built-in that should not be there.
    case other
}

public enum ToolClassifier {
    /// Spec §6.5's name rule: these words make a tool a read.
    static let readWords: Set<String> = ["list", "get", "search", "read", "fetch", "query"]
    /// A name that also says it changes something is a write whatever else it says ("get_or_create").
    static let writeWords: Set<String> = ["send", "create", "update", "delete", "trash", "untrash", "remove", "move", "reply", "forward",
                                          "archive", "upload", "mark", "label", "unlabel", "respond", "schedule", "cancel", "edit",
                                          "merge", "publish", "share", "invite", "add", "set", "apply", "rename", "replace", "write"]

    public static func classify(_ toolName: String, connectors: ConnectorTable) -> ToolClass {
        if toolName == "ToolSearch" { return .toolSearch }
        // The permission-prompt tool is Claude Code's to call, never the model's.
        if toolName == "mcp__iris__approval" { return .other }
        if toolName.hasPrefix("mcp__iris__") { return .iris }
        guard let (connector, tool) = connectors.connector(forTool: toolName) else { return .other }
        if let annotations = connector.tools[tool] {
            if annotations.readOnly { return .connectorRead(connector, tool: tool) }
            if annotations.destructive { return .connectorWrite(connector, tool: tool) }
        }
        return isReadByName(tool) ? .connectorRead(connector, tool: tool) : .connectorWrite(connector, tool: tool)
    }

    /// Words of a tool name, split at `_`, `-`, `.`, spaces and lowerCamel humps, lower-cased.
    static func words(_ name: String) -> [String] {
        var words: [String] = [], current = ""
        for character in name {
            if character.isLetter || character.isNumber {
                if character.isUppercase, let last = current.last, last.isLowercase { words.append(current); current = "" }
                current.append(character)
            } else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    static func isReadByName(_ name: String) -> Bool {
        let words = Set(words(name))
        return words.isDisjoint(with: writeWords) && !words.isDisjoint(with: readWords)
    }
}
