import Foundation

/// How `iris-bridge mcp` reaches the running helper. A protocol so the MCP server is tested without a socket.
public protocol ToolCalling: AnyObject {
    /// The `tools/call` result object (`{content, isError}`) the helper answered with. `turnId` groups a terminal
    /// agent's burst of calls the way a chat turn groups a model's (the app's batch rule counts per turn).
    func call(name: String, arguments: JSONValue, threadId: String?, turnId: String, agent: String) throws -> JSONValue
}

/// Loopback to this Mac's helper, with the admin token. Built per call, because the helper can be installed or
/// restarted while Claude Code keeps the same MCP process alive for hours.
public final class LoopbackToolClient: ToolCalling {
    /// Long enough for an approval (10 minutes) with room to spare; other tools answer within 30 seconds.
    static let approvalTimeout: TimeInterval = 660
    static let toolTimeout: TimeInterval = 90

    private let paths: BridgePaths
    private let port: UInt16
    public init(paths: BridgePaths, port: UInt16) { self.paths = paths; self.port = port }

    public func call(name: String, arguments: JSONValue, threadId: String?, turnId: String, agent: String) throws -> JSONValue {
        var body: [String: JSONValue] = ["name": .string(name), "arguments": arguments, "turnId": .string(turnId), "agent": .string(agent)]
        if let threadId { body["threadId"] = .string(threadId) }
        return try AdminClient(paths: paths, port: port)
            .callTool(JSONValue.object(body).encoded(), timeout: name == "approval" ? Self.approvalTimeout : Self.toolTimeout)
    }
}
