import Foundation

/// What the approval rules need to know about the turn a tool use belongs to (spec §6.5).
public struct TurnContext: Equatable {
    public var threadId: String
    public var turnId: String
    public var provider: Provider
    /// Connectors the message mentioned with `@`.
    public var mentions: Set<String>
    /// Connectors the turn's Iris command declares.
    public var commandConnectors: Set<String>
    public var connectors: ConnectorTable

    public init(threadId: String, turnId: String, provider: Provider, mentions: Set<String>, commandConnectors: Set<String>, connectors: ConnectorTable) {
        self.threadId = threadId; self.turnId = turnId; self.provider = provider
        self.mentions = mentions; self.commandConnectors = commandConnectors; self.connectors = connectors
    }
}

public enum ApprovalDecision: Equatable {
    case allow
    case deny(String)
    /// The owner decides (`approval.request`).
    case ask(kind: String, summary: String, detail: JSONValue)
}

/// Spec §6.5, as one pure function: Iris tools and tool search run; a connector read runs only in a turn that
/// mentioned that connector or whose command declares it; a connector write waits for the owner; anything else
/// is refused with a reason the model can read.
public enum ApprovalPolicy {
    public static func decide(toolName: String, input: JSONValue, turn: TurnContext?) -> ApprovalDecision {
        guard let turn else { return .deny("This chat has no message being answered, so no tool can run.") }
        switch ToolClassifier.classify(toolName, connectors: turn.connectors) {
        case .iris, .toolSearch:
            return .allow
        case .connectorRead(let connector, _):
            if turn.mentions.contains(connector.id) || turn.commandConnectors.contains(connector.id) { return .allow }
            return .deny("Reading \(connector.name) needs the creator to mention it with @\(connector.name) in their message. Ask them to, or answer without it.")
        case .connectorWrite(let connector, let tool):
            let action = ToolClassifier.words(tool).joined(separator: " ")
            return .ask(kind: "connectorWrite", summary: "\(connector.name): \(action)",
                        detail: ["connector": .string(connector.name), "tool": .string(tool), "input": input])
        case .other:
            return .deny("That tool is not available in Iris chat.")
        }
    }
}
