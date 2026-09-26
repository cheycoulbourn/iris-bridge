import Foundation

/// The helper's side of every Iris tool call. `iris-bridge mcp` forwards each `tools/call` here over loopback
/// (`POST /admin/v3/tool`, contract §8), so chat sessions and terminal agents share one snapshot, one queue of
/// changes and one set of approval rules.
public final class ToolService: @unchecked Sendable {
    private let reads: IrisReadTools
    private let relay: ActionRelay
    private let approvals: ApprovalBroker
    private let snapshots: SnapshotStore
    private let turns: TurnContextProvider

    public init(reads: IrisReadTools, relay: ActionRelay, approvals: ApprovalBroker, snapshots: SnapshotStore, turns: TurnContextProvider) {
        self.reads = reads; self.relay = relay; self.approvals = approvals; self.snapshots = snapshots; self.turns = turns
    }

    /// `threadId` is set for a chat session the helper started (`iris-bridge mcp --thread`); `turnId` is a terminal
    /// agent's burst of work (`MCPServer.burstGap`), used when there is no chat turn; `agent` is the MCP client.
    public func call(name: String, arguments: [String: JSONValue], threadId: String?, turnId: String?, agent: String) -> ToolResult {
        if name == "approval" {
            guard let threadId else { return .failure("approval is only for chat sessions Iris Bridge starts.") }
            let answer = approvals.check(threadId: threadId, toolName: arguments["tool_name"]?.stringValue ?? "", input: arguments["input"] ?? [:])
            return ToolResult(text: String(decoding: answer.encoded(), as: UTF8.self))
        }
        if let read = reads.call(name, arguments) { return read }
        let turn = threadId.flatMap(turns.turnContext(threadId:))
        let who = turn?.provider.rawValue ?? agent
        let actionId = ActionRelay.newActionId()
        do {
            let actions: [JSONValue]
            var revisionOf: String?
            if name == "iris_revise_review_item" {
                let (tool, input, itemID) = try revision(arguments)
                actions = try IrisChangeTools.actions(tool: tool, arguments: input, actionId: actionId)
                revisionOf = itemID
            } else {
                actions = try IrisChangeTools.actions(tool: name, arguments: arguments, actionId: actionId)
            }
            let origin = IrisChangeTools.origin(agent: who, threadId: threadId, turnId: turn?.turnId ?? turnId, revisionOf: revisionOf)
            switch relay.request(actionId: actionId, actions: actions, origin: origin, threadId: threadId) {
            case .answered(let result): return IrisChangeTools.result(result)
            case .queued: return IrisChangeTools.queued(actionId: actionId)
            }
        } catch {
            if IrisToolCatalog.tool(named: name) == nil { return .failure("iris-bridge has no tool called \(name).") }
            return .failure((error as? BridgeError)?.errorDescription ?? "Iris Bridge could not send that change.")
        }
    }

    /// A revision replaces an Inbox item the creator asked to change; it is checked against the Inbox Iris
    /// shared, so a typo cannot leave a revision pointing at nothing.
    private func revision(_ arguments: [String: JSONValue]) throws -> (tool: String, input: [String: JSONValue], itemID: String) {
        guard let itemID = arguments["itemID"]?.stringValue, let tool = arguments["tool"]?.stringValue,
              var input = arguments["input"]?.objectValue else {
            throw BridgeError.message("iris_revise_review_item needs itemID, tool and input.")
        }
        guard tool != "iris_revise_review_item", IrisToolCatalog.tool(named: tool)?.kind == .change else {
            throw BridgeError.message("\(tool) is not an Iris change tool.")
        }
        guard let held = snapshots.snapshot(profileID: arguments["profileID"]?.stringValue), held.snapshot.source == .stream else {
            throw BridgeError.message("Iris has not shared its Inbox with this Mac yet. Open Iris on a paired device, then try again.")
        }
        guard let item = held.snapshot.reviewItems.first(where: { $0.id == itemID }) else {
            throw BridgeError.message("That Inbox item was not found. Read iris_list_review_items for its id.")
        }
        guard item.status == "changesRequested" else {
            throw BridgeError.message("The creator has not asked for changes to that item, so it cannot be revised.")
        }
        if let profile = arguments["profileID"] { input["profileID"] = profile }
        return (tool, input, itemID)
    }
}
