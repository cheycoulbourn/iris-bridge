import Foundation

/// The Iris toolset (spec §5.1) as MCP tool definitions: one list for Claude Code and Codex in a terminal and
/// for chat sessions alike. The change tools' input shapes mirror the app's `Iris/Actions/IrisActionRequests.swift`
/// (phase 2) field for field, plus `profileID` on every tool. v0.2.x tool names are gone (§5.1).
public enum IrisToolCatalog {
    public enum Kind: Equatable { case read, change }

    public struct Tool {
        public var name: String
        public var kind: Kind
        /// What a chat card says while the tool runs: "Reading your posts".
        public var activity: String
        public var description: String
        public var properties: [String: JSONValue]
        public var required: [String]

        public var definition: JSONValue {
            var props = properties
            props["profileID"] = ["type": "string", "description": "The profile (account) id from iris_workspace_summary. Leave it out for the profile open in Iris."]
            return ["name": .string(name), "description": .string(description),
                    "inputSchema": ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })],
                    "annotations": kind == .read ? ["readOnlyHint": true] : ["readOnlyHint": false, "destructiveHint": false]]
        }
    }

    /// Workflow stages, as the app names them (`WorkflowStage`).
    public static let stages = ["drafted", "scripting", "toFilm", "filming", "rawFootage", "toEdit", "editing", "editingReview",
                                "revisionReview", "finalEdits", "finalReview", "approved", "changesRequested", "denied", "cancelled",
                                "captions", "ready", "scheduled", "published"]

    static let rules = "Call iris_workspace_summary first and use pillar, platform and format names exactly as it spells them. Keep the creator's own writing exactly as written when you import it. Drafts created in chat wait for the creator's approval in the Inbox before entering the planner. Other small changes apply at once and the creator can undo them in Activity; posting dates, stages past editing, marking posted, archiving and new series wait for Inbox approval. Each result says which happened; queued_for_review means pending review."

    private static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    private static let date = string("A day, as yyyy-MM-dd.")
    private static let time = string("A time of day, as HH:mm (24-hour).")
    private static let id = string("A UUID from a read tool.")
    private static let integer: JSONValue = ["type": "integer", "minimum": 0]

    private static var sceneInput: JSONValue {
        ["type": "object", "properties": ["id": string("An existing scene's id, when revising it."), "script": string("What is said or shown."),
                                          "shotNotes": string("How to shoot it.")]]
    }

    private static var postFields: [String: JSONValue] {
        ["title": string("Short working title."), "pillar": string("An existing pillar name."), "platform": string("An existing platform name."),
         "format": string("A format that platform uses, such as Reel."), "hook": string("The opening line."), "script": string("The full script."),
         "scenes": ["type": "array", "items": sceneInput, "description": "Scene by scene, when the post is shot in parts."],
         "caption": string("The caption as it would be posted."), "cta": string("What to ask the viewer to do."),
         "notes": string("Anything the creator should know."),
         "stage": ["type": "string", "enum": .array(stages.map { .string($0) }), "description": "A workflow stage; drafts past editing wait for approval."]]
    }

    public static let reads: [Tool] = [
        Tool(name: "iris_workspace_summary", kind: .read, activity: "Reading your workspace",
             description: "Describe the creator's workspace: profiles and which one is open, pillars (the anchor one marked) and their usual weekdays, platforms with formats and weekly goals, counts of posts by stage, open tasks, ideas and series, today's date and time zone, and how old this snapshot is. Call this before planning anything.",
             properties: [:], required: []),
        Tool(name: "iris_list_posts", kind: .read, activity: "Reading your posts",
             description: "List planner posts, newest date first, filtered by date range, stage, pillar, platform, series or text. Returns summaries; use iris_get_post for one post in full.",
             properties: ["from": date, "to": date, "stage": ["type": "string", "enum": .array(stages.map { .string($0) })], "pillar": string("A pillar name."),
                          "platform": string("A platform name."), "seriesID": id, "text": string("Text to find in the title, hook, script or caption."),
                          "includeArchived": ["type": "boolean"], "offset": integer, "limit": ["type": "integer", "minimum": 1, "maximum": 100]],
             required: []),
        Tool(name: "iris_get_post", kind: .read, activity: "Reading a post",
             description: "Read one post in full: every text field, its scenes, stage, date and revision. Pass its revision as expectedRevision when you change it.",
             properties: ["postID": id], required: ["postID"]),
        Tool(name: "iris_list_tasks", kind: .read, activity: "Reading your tasks",
             description: "List tasks, open ones by default, with due dates, subtasks and the post each belongs to.",
             properties: ["status": ["type": "string", "enum": ["open", "done", "all"]], "from": date, "to": date, "postID": id, "text": string("Text to find.")],
             required: []),
        Tool(name: "iris_list_ideas", kind: .read, activity: "Reading your ideas",
             description: "List ideas in the idea bank, optionally for one pillar or matching text.",
             properties: ["pillar": string("A pillar name."), "text": string("Text to find."), "includeArchived": ["type": "boolean"]], required: []),
        Tool(name: "iris_list_series", kind: .read, activity: "Reading your series",
             description: "List series with their episode slots, dates and the post filling each slot.",
             properties: ["includeArchived": ["type": "boolean"]], required: []),
        Tool(name: "iris_list_pillars", kind: .read, activity: "Reading your pillars",
             description: "List content pillars with their descriptions, anchor flag and usual posting weekdays.", properties: [:], required: []),
        Tool(name: "iris_get_schedule", kind: .read, activity: "Reading your schedule",
             description: "For each day in a range of up to 62 days: the posts dated that day, the tasks due, and the day's focus themes.",
             properties: ["from": date, "to": date], required: ["from", "to"]),
        Tool(name: "iris_search", kind: .read, activity: "Searching your workspace",
             description: "Find posts, tasks, ideas and series whose text contains the words given.",
             properties: ["text": string("Words to find."), "kinds": ["type": "array", "items": ["type": "string", "enum": ["post", "task", "idea", "series"]]]],
             required: ["text"]),
        Tool(name: "iris_find_duplicate_posts", kind: .read, activity: "Looking for duplicate posts",
             description: "Group active posts that share a title, platform and format. Candidates only; nothing is selected or changed.",
             properties: [:], required: []),
        Tool(name: "iris_list_review_items", kind: .read, activity: "Reading your Inbox",
             description: "List what waits in the creator's Inbox, with each item's status and any comment. Use it to find an item the creator asked you to change.",
             properties: ["status": ["type": "string", "enum": ["pending", "all"]]], required: [])
    ]

    public static var changes: [Tool] {
        [
            Tool(name: "iris_create_task", kind: .change, activity: "Adding a task", description: "Add a task. " + rules,
                 properties: ["title": string("What to do."), "notes": string("Details."), "dueDate": date, "dueTime": time,
                              "subtasks": ["type": "array", "items": ["type": "string"]], "postID": id], required: ["title"]),
            Tool(name: "iris_update_task", kind: .change, activity: "Updating a task", description: "Change a task's title, notes, due date or subtasks. An empty dueDate clears it. " + rules,
                 properties: ["taskID": id, "title": string("New title."), "notes": string("New notes."), "dueDate": date, "dueTime": time,
                              "subtasks": ["type": "array", "items": ["type": "string"]], "postID": id], required: ["taskID"]),
            Tool(name: "iris_complete_task", kind: .change, activity: "Completing a task", description: "Mark a task done. " + rules,
                 properties: ["taskID": id], required: ["taskID"]),
            Tool(name: "iris_create_idea", kind: .change, activity: "Adding an idea", description: "Add an idea to the idea bank. " + rules,
                 properties: ["title": string("The idea in a few words."), "note": string("More about it."), "pillar": string("An existing pillar name.")], required: ["title"]),
            Tool(name: "iris_update_idea", kind: .change, activity: "Updating an idea", description: "Change an idea. " + rules,
                 properties: ["ideaID": id, "title": string("New title."), "note": string("New note."), "pillar": string("An existing pillar name.")], required: ["ideaID"]),
            Tool(name: "iris_create_post_draft", kind: .change, activity: "Drafting a post",
                 description: "Submit a completed suggested post draft for the creator to review. Drafts created in chat wait in the Inbox, linked to this conversation. Give date (and time) to also request its posting date, reviewed with the draft. " + rules,
                 properties: postFields.merging(["date": date, "time": time]) { $1 }, required: ["title"]),
            Tool(name: "iris_update_post_draft", kind: .change, activity: "Editing a post",
                 description: "Change a post's text: title, hook, script, scenes, caption, CTA, notes, pillar, platform or format. Pass the revision iris_get_post returned as expectedRevision; a post changed since is not overwritten. " + rules,
                 properties: postFields.filter { $0.key != "stage" }.merging(["postID": id, "expectedRevision": string("The revision iris_get_post returned.")]) { $1 },
                 required: ["postID"]),
            Tool(name: "iris_attach_to_post", kind: .change, activity: "Attaching a link", description: "Attach a link to a post. " + rules,
                 properties: ["postID": id, "url": string("An https link."), "label": string("What the link is.")], required: ["postID", "url"]),
            Tool(name: "iris_schedule_post", kind: .change, activity: "Setting a posting date", description: "Set or change a post's posting date. Waits for approval. " + rules,
                 properties: ["postID": id, "date": date, "time": time], required: ["postID", "date"]),
            Tool(name: "iris_set_stage", kind: .change, activity: "Moving a post",
                 description: "Move a post to a workflow stage. Stages up to editing apply at once; later ones wait for approval. " + rules,
                 properties: ["postID": id, "stage": ["type": "string", "enum": .array(stages.map { .string($0) })]], required: ["postID", "stage"]),
            Tool(name: "iris_mark_posted", kind: .change, activity: "Marking a post posted", description: "Mark a post as posted, with its live link. Waits for approval. " + rules,
                 properties: ["postID": id, "liveURL": string("The post's public link.")], required: ["postID"]),
            Tool(name: "iris_archive", kind: .change, activity: "Archiving",
                 description: "Archive up to 100 posts, tasks, ideas or series together. Nothing is ever deleted; the creator approves it and can restore it. " + rules,
                 properties: ["records": ["type": "array", "minItems": 1, "maxItems": 100,
                                          "items": ["type": "object", "properties": ["kind": ["type": "string", "enum": ["post", "task", "idea", "series"]], "id": id,
                                                                                   "expectedRevision": string("The revision a read tool returned.")],
                                                    "required": ["kind", "id"]]]],
                 required: ["records"]),
            Tool(name: "iris_create_series", kind: .change, activity: "Planning a series",
                 description: "Plan a series: a name, a pillar and one post per episode. Waits for approval. " + rules,
                 properties: ["name": string("What the series is called."), "pillar": string("An existing pillar name."), "summary": string("One or two sentences."),
                              "episodes": ["type": "array", "items": ["type": "object",
                                                                      "properties": ["number": ["type": "integer", "minimum": 1], "date": date,
                                                                                     "post": ["type": "object", "properties": .object(postFields), "required": ["title"]]],
                                                                      "required": ["number", "post"]]]],
                 required: ["name", "episodes"]),
            Tool(name: "iris_revise_review_item", kind: .change, activity: "Revising a request",
                 description: "Replace an Inbox item the creator asked you to change (status changesRequested): name the change tool and its full input. The revision waits for review again. " + rules,
                 properties: ["itemID": string("The item id from iris_list_review_items."), "tool": string("The change tool to run instead, such as iris_create_post_draft."),
                              "input": ["type": "object", "description": "That tool's full input."]],
                 required: ["itemID", "tool", "input"])
        ]
    }

    /// The permission-prompt tool Claude calls before a tool use (spec §6.5). Listed only to chat sessions the
    /// helper starts (`iris-bridge mcp --thread`), never to a terminal agent.
    public static let approval: JSONValue = [
        "name": "approval",
        "description": "Iris's permission check for chat sessions. Claude Code calls it; it is not for direct use.",
        "inputSchema": ["type": "object", "properties": ["tool_name": ["type": "string"], "input": ["type": "object"], "tool_use_id": ["type": "string"]],
                        "required": ["tool_name", "input"]]
    ]

    public static var all: [Tool] { reads + changes }

    public static func tool(named name: String) -> Tool? { all.first { $0.name == name } }

    /// The MCP `tools/list` answer.
    public static func list(includingApproval: Bool) -> JSONValue {
        .array(all.map(\.definition) + (includingApproval ? [approval] : []))
    }
}

/// One MCP `tools/call` result: a sentence or JSON text for the model, and whether it failed.
public struct ToolResult: Equatable {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) { self.text = text; self.isError = isError }
    public static func failure(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
    public static func json(_ value: JSONValue) -> ToolResult { ToolResult(text: String(decoding: value.encoded(), as: UTF8.self)) }
    public var json: JSONValue { ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)] }
}
