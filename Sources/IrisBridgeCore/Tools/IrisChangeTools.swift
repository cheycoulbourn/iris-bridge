import Foundation

/// A change tool call as the Iris actions it stands for (contract §4): the `IrisAction` envelopes the app's
/// executor reads (`{id, name, profileID, input}`, phase 2's `Iris/Actions/IrisActionVocabulary.swift`). One
/// call is one request: a draft with a date is a draft and its date, reviewed together; one archive call is one
/// review item however many records it names.
public enum IrisChangeTools {
    public static func actions(tool: String, arguments: [String: JSONValue], actionId: String) throws -> [JSONValue] {
        guard let definition = IrisToolCatalog.tool(named: tool), definition.kind == .change, tool != "iris_revise_review_item" else {
            throw BridgeError.message("\(tool) is not an Iris change tool.")
        }
        var input = arguments
        let profile = input.removeValue(forKey: "profileID")
        if let profile, profile != .null, profile.stringValue.flatMap(UUID.init(uuidString:)) == nil {
            throw BridgeError.message("profileID must be a profile id from iris_workspace_summary.")
        }
        for key in definition.required where input[key] == nil || input[key] == .null {
            throw BridgeError.message("\(tool) needs \(key).")
        }
        func envelope(_ index: Int, _ name: String, _ input: [String: JSONValue]) -> JSONValue {
            var body: [String: JSONValue] = ["id": .string("\(actionId).\(index)"), "name": .string(name), "input": .object(input)]
            if let uuid = profile?.stringValue.flatMap(UUID.init(uuidString:)) { body["profileID"] = .string(uuid.uuidString) }
            return .object(body)
        }
        switch tool {
        case "iris_create_post_draft":
            let date = input.removeValue(forKey: "date"), time = input.removeValue(forKey: "time")
            guard let date, date != .null else { return [envelope(0, tool, input)] }
            var schedule: [String: JSONValue] = ["date": date]
            if let time, time != .null { schedule["time"] = time }
            return [envelope(0, tool, input), envelope(1, "iris_schedule_post", schedule)]
        case "iris_archive":
            guard let records = input["records"]?.arrayValue, (1...100).contains(records.count) else {
                throw BridgeError.message("iris_archive needs 1 to 100 records.")
            }
            return try records.enumerated().map { index, record in
                guard let fields = record.objectValue, ["post", "task", "idea", "series"].contains(fields["kind"]?.stringValue ?? ""),
                      fields["id"]?.stringValue != nil else {
                    throw BridgeError.message("Each record to archive needs its kind (post, task, idea or series) and id.")
                }
                return envelope(index, tool, fields)
            }
        default:
            return [envelope(0, tool, input)]
        }
    }

    /// The origin every action from one call carries (phase 2's `IrisActionOrigin`): a chat turn, or an agent
    /// in a terminal.
    public static func origin(agent: String, threadId: String?, turnId: String?, revisionOf: String? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["source": .string(threadId == nil ? "agent" : "chat"), "agent": .string(agent)]
        if let threadId { body["threadID"] = .string(threadId) }
        if let turnId { body["turnID"] = .string(turnId) }
        if let revisionOf { body["revisionOf"] = .string(revisionOf) }
        return .object(body)
    }

    /// What the model reads back (phase 2's `IrisActionOutcome` as `action.result` carries it).
    public static func result(_ answer: JSONValue) -> ToolResult {
        switch answer["status"]?.stringValue {
        case "ok":
            var body: [String: JSONValue] = ["status": "ok", "note": "Saved in Iris. The creator can undo it in Activity."]
            body["recordIDs"] = answer["recordIDs"]; body["activityID"] = answer["activityID"]
            return .json(.object(body))
        case "queued_for_review":
            return .json(["status": "queued_for_review", "itemID": answer["itemID"] ?? .null,
                          "note": "Waiting for the creator's approval in the Inbox."])
        case "refused":
            return .failure(answer["message"]?.stringValue ?? "Iris refused that change.")
        default:
            return .failure("Iris answered in a way this Iris Bridge does not understand. Update Iris Bridge.")
        }
    }

    public static func queued(actionId: String) -> ToolResult {
        .json(["status": "queued_until_iris_connects", "actionId": .string(actionId),
               "note": "Iris is not open on a paired device. The change waits on this Mac; Iris applies it, or puts it in the Inbox for review, when it next connects."])
    }
}
