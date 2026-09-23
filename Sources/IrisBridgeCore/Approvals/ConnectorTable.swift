import Foundation

/// The owner's Claude account connectors, as a session's `mcp_status` control response reports them (spec
/// §6.4, §6.6): which are connected, and what each tool's MCP annotations say. Only servers with scope
/// `claudeai` are connectors; the helper's own `iris` server and the Mac's other MCP servers are not.
public struct ConnectorTable: Equatable, Sendable {
    public struct Connector: Equatable, Sendable {
        /// The server name as Claude Code puts it in tool ids: "claude.ai Gmail" → "claude_ai_Gmail".
        public var id: String
        /// "Gmail".
        public var name: String
        /// `connected`, `needs-auth`, `failed` or `pending`.
        public var status: String
        /// Tool name → (readOnly, destructive), from Claude Code's rendering of the MCP annotations.
        public var tools: [String: Annotations]
    }

    public struct Annotations: Equatable, Sendable { public var readOnly: Bool; public var destructive: Bool }

    public var connectors: [Connector]

    public init(connectors: [Connector] = []) { self.connectors = connectors }

    /// Reads the `response` of an `mcp_status` control response: `{mcpServers: [{name, status, scope, tools:
    /// [{name, annotations}]}]}`.
    public init(mcpStatus: JSONValue) {
        connectors = (mcpStatus["mcpServers"]?.arrayValue ?? []).compactMap { server in
            guard server["scope"]?.stringValue == "claudeai", let name = server["name"]?.stringValue else { return nil }
            var tools: [String: Annotations] = [:]
            for tool in server["tools"]?.arrayValue ?? [] {
                guard let toolName = tool["name"]?.stringValue else { continue }
                tools[toolName] = Annotations(readOnly: tool["annotations"]?["readOnly"]?.boolValue ?? false,
                                              destructive: tool["annotations"]?["destructive"]?.boolValue ?? false)
            }
            let display = name.hasPrefix("claude.ai ") ? String(name.dropFirst("claude.ai ".count)) : name
            return Connector(id: Self.normalize(name), name: display, status: server["status"]?.stringValue ?? "", tools: tools)
        }
    }

    /// Claude Code's tool-id form of a server name: every character outside `A-Z a-z 0-9 _ -` becomes `_`.
    public static func normalize(_ serverName: String) -> String {
        String(serverName.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-") ? Character(scalar) : "_"
        })
    }

    /// The connector a tool id belongs to (`mcp__claude_ai_Gmail__search_threads`), and the tool's own name.
    public func connector(forTool toolName: String) -> (connector: Connector, tool: String)? {
        for connector in connectors {
            let prefix = "mcp__" + connector.id + "__"
            if toolName.hasPrefix(prefix) { return (connector, String(toolName.dropFirst(prefix.count))) }
        }
        return nil
    }

    /// What Health reports (contract §6): the `@` menu's list.
    public var json: JSONValue {
        .array(connectors.map { ["id": .string($0.id), "name": .string($0.name), "status": .string($0.status), "tools": .number(Double($0.tools.count))] })
    }
}
