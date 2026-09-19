import Foundation

// MARK: - Transport

/// One JSON-RPC message per line, UTF-8, newline-delimited — what Claude Code's stdio transport speaks.
public protocol MCPTransport {
    /// The next message, or `nil` at end of input.
    func readMessage() throws -> Data?
    func writeMessage(_ data: Data) throws
}

/// The stdio transport. Reading is line-oriented rather than chunk-oriented because a client is free to hand
/// over two messages in one write, and a transport that answered "a read" with "a message" would drop the
/// second one. Stdout carries nothing but JSON-RPC: anything else on it corrupts the stream, so every log
/// line in this subcommand goes to stderr.
public final class StdioMCPTransport: MCPTransport {
    private let input: FileHandle
    private let output: FileHandle
    private var buffer: [UInt8] = []
    private var reachedEnd = false

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input; self.output = output
    }

    public func readMessage() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Self.trimmed(Array(buffer[..<newline]))
                buffer.removeFirst(newline + 1)
                // A blank line is framing, not a message: answering -32700 to one would push an error at a
                // client that asked nothing.
                if line.isEmpty { continue }
                return Data(line)
            }
            if reachedEnd {
                let line = Self.trimmed(buffer)
                buffer.removeAll()
                return line.isEmpty ? nil : Data(line)
            }
            // `availableData` returns as soon as the pipe has anything and an empty Data at end of input.
            // `read(upToCount:)` waits for the full count or EOF, and Claude Code never closes stdin — so the
            // reply to `initialize` sat behind a read that could not finish, and every connection timed out.
            let chunk = input.availableData
            if chunk.isEmpty { reachedEnd = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    public func writeMessage(_ data: Data) throws {
        var line = data
        line.append(0x0A)
        try output.write(contentsOf: line)
    }

    /// Trailing carriage return and surrounding spaces; a client that writes CRLF is not writing a bad message.
    private static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var slice = bytes[...]
        while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0D { slice = slice.dropFirst() }
        while let last = slice.last, last == 0x20 || last == 0x09 || last == 0x0D { slice = slice.dropLast() }
        return Array(slice)
    }
}

// MARK: - Server

/// The MCP server behind `iris-bridge mcp`: JSON-RPC 2.0 over stdio, planner reads and review-only proposals, and nothing of its own to
/// store. Every tool call goes back through loopback to the running helper, so the agent and the creator are
/// always looking at the same inbox.
public struct MCPServer {
    public static let protocolVersion = "2025-06-18"
    /// Newest first. Both revisions use the same stdio framing, so a client pinned to the older one is
    /// answered in the version it asked for rather than told to speak a newer one.
    public static let protocolVersions = ["2025-06-18", "2024-11-05"]
    public static let notRunning = "Iris Bridge is not running. Run `iris-bridge status` on this Mac."

    /// Called by `iris-bridge mcp` before the first byte is read. The client owns stdout, and a client that
    /// closes it before the last reply is written would otherwise kill this process with SIGPIPE in the middle
    /// of a sentence. Ignored, that write fails like any other and the read loop ends at EOF instead.
    public static func ignoreBrokenPipe() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// The client that connected, remembered from `initialize` so a submission says who sent it. A reference
    /// box because `handle` answers one message at a time and must not need a `var` server to do it.
    private final class State { var agent = "agent" }

    private let client: AdminClientProtocol
    private let version: String
    private let state = State()

    public init(client: AdminClientProtocol, version: String) {
        self.client = client; self.version = version
    }

    /// One message in, at most one message out. Notifications get `nil`: JSON-RPC forbids answering them,
    /// and a reply on stdout to a message with no id is a protocol error the client cannot even match up.
    public func handle(_ requestJSON: Data) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: requestJSON)) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(),
                                "error": ["code": -32700, "message": "Could not read that JSON-RPC message."]])
        }
        let method = message["method"] as? String ?? ""
        guard let id = message["id"], !(id is NSNull) else {
            if method == "initialize" { rememberClient(message["params"] as? [String: Any]) }
            return nil
        }
        guard !method.isEmpty else {
            return Self.encode(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32600, "message": "That request has no method."]])
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            rememberClient(params)
            return reply(id, ["protocolVersion": Self.negotiated(params["protocolVersion"]),
                              "capabilities": ["tools": [String: Any]()],
                              "serverInfo": ["name": "iris-bridge", "version": version]])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            return reply(id, call(name: params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32601, "message": "iris-bridge does not handle \(method)."]])
        }
    }

    /// Reads until end of input. Returns when the client closes the pipe, which is how Claude Code shuts an
    /// MCP server down.
    public func run(transport: MCPTransport) throws {
        while let message = try transport.readMessage() {
            if let answer = handle(message) { try transport.writeMessage(answer) }
        }
    }

    /// The version to answer `initialize` with: the client's own when it is one this server speaks, and this
    /// server's newest otherwise — which is how MCP says a server tells a client "not that one, this one".
    static func negotiated(_ requested: Any?) -> String {
        guard let asked = requested as? String, protocolVersions.contains(asked) else { return protocolVersion }
        return asked
    }

    private func rememberClient(_ params: [String: Any]?) {
        let name = (params?["clientInfo"] as? [String: Any])?["name"] as? String ?? ""
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if !clean.isEmpty { state.agent = clean }
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> Data? {
        Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not write that reply."}}"#.utf8)
    }

    // MARK: - Tools

    private static let rules = "Call iris_get_workspace_context first and use only pillar, platform and format names that already exist there. Preserve imported creator writing verbatim, including punctuation, line breaks, facts, hooks and captions. Never shorten or paraphrase existing work. Ask the creator to clarify ambiguous field mappings, dates, stages, ownership and merge targets before importing. Read existing submissions before sending work; use iris_revise_submission for requested changes, never a new submission. Nothing is saved until the creator approves it in Iris."

    private static let sceneSchema: [String: Any] = [
        "type": "object",
        "properties": ["script": ["type": "string", "description": "What is said or shown in this scene."],
                       "shotNotes": ["type": "string", "description": "How to shoot it."]],
        "required": ["script", "shotNotes"]
    ]

    private static var postProperties: [String: Any] {
        [
            "title": ["type": "string", "description": "Short working title for the post."],
            "pillar": ["type": "string", "description": "An existing pillar name, exactly as the workspace spells it."],
            "platform": ["type": "string", "description": "An existing platform name, exactly as the workspace spells it."],
            "format": ["type": "string", "description": "A format that platform already uses, such as Reel or Carousel."],
            "postingDate": ["type": "string", "description": "The day to post, as yyyy-MM-dd. Leave it out for a draft with no date."],
            "hook": ["type": "string", "description": "The opening line, verbatim when importing existing work."],
            "script": ["type": "string", "description": "The full script, when the post is one piece to camera."],
            "scenes": ["type": "array", "description": "Scene by scene, when the post is shot in parts.", "items": sceneSchema],
            "caption": ["type": "string", "description": "The caption as it would be posted."],
            "cta": ["type": "string", "description": "What to ask the viewer to do."],
            "notes": ["type": "string", "description": "Anything the creator should know while shooting."],
            "seriesName": ["type": "string", "description": "The series this belongs to, if it belongs to one."],
            "episode": ["type": "integer", "description": "Which episode of that series this is."]
        ]
    }

    private static var postSchema: [String: Any] {
        ["type": "object", "properties": postProperties, "required": ["title", "pillar", "platform", "format"]]
    }

    private static var episodeSchema: [String: Any] {
        ["type": "object",
         "properties": ["number": ["type": "integer", "description": "Episode number, starting at 1."],
                        "date": ["type": "string", "description": "The day to post this episode, as yyyy-MM-dd."],
                        "post": postSchema],
         "required": ["number", "post"]]
    }

    static var tools: [[String: Any]] {
        var submitPostProperties = postProperties
        submitPostProperties["note"] = ["type": "string", "description": "A short cover note for the creator, saying why you made this."]
        return [
            [
                "name": "iris_get_workspace_context",
                "description": "Describe the creator's workspace: their name, their pillars (with the anchor one marked) and the weekdays each one usually posts, their platforms with formats and weekly goals, their series with episode slots, and their own notes about how they work. Call this before planning anything and use the names it returns exactly.",
                "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()]
            ],
            [
                "name": "iris_submit_post",
                "description": "Send one planned post to the creator's Iris Inbox for review. " + rules,
                "inputSchema": ["type": "object", "properties": submitPostProperties,
                                "required": ["title", "pillar", "platform", "format"]]
            ],
            [
                "name": "iris_submit_series",
                "description": "Send a planned series — a name, a pillar and one post per episode — to the creator's Iris Inbox for review. " + rules,
                "inputSchema": ["type": "object",
                                "properties": ["name": ["type": "string", "description": "What the series is called."],
                                               "pillar": ["type": "string", "description": "An existing pillar name, exactly as the workspace spells it."],
                                               "summary": ["type": "string", "description": "One or two sentences on what the series is."],
                                               "episodes": ["type": "array", "description": "One entry per episode, in order.", "items": episodeSchema],
                                               "note": ["type": "string", "description": "A short cover note for the creator."]],
                                "required": ["name", "pillar", "episodes"]]
            ],
            [
                "name": "iris_list_submissions",
                "description": "List what has already been sent to the creator, newest first, with each one's status and any comment they left. Use it to find the id of something you were asked to change.",
                "inputSchema": ["type": "object",
                                "properties": ["status": ["type": "string", "enum": ["pending", "all"],
                                                          "description": "\"pending\" for what is still waiting (the default), \"all\" for everything including decided ones."]],
                                "required": [String]()]
            ],
            [
                "name": "iris_revise_submission",
                "description": "Replace a submission the creator asked you to change: pass its id and a complete replacement post or series. The original stays in their history. " + rules,
                "inputSchema": ["type": "object",
                                "properties": ["id": ["type": "string", "description": "The id of the submission being revised, like sub_a1b2c3d4e5f6."],
                                               "post": postSchema,
                                               "series": ["type": "object",
                                                          "properties": ["name": ["type": "string"], "pillar": ["type": "string"],
                                                                         "summary": ["type": "string"],
                                                                         "episodes": ["type": "array", "items": episodeSchema]],
                                                          "required": ["name", "pillar", "episodes"]],
                                               "note": ["type": "string", "description": "A short note on what you changed."]],
                                "required": ["id"]]
            ],
            [
                "name": "iris_list_posts",
                "description": "Read saved planner posts for one account. Returns exact titles and snapshot metadata; it never changes posts. Use search to find text, includeArchived to include archived records, and offset/limit for complete pagination.",
                "inputSchema": ["type": "object",
                                "properties": ["accountID": ["type": "string", "description": "The account UUID from the planner snapshot."],
                                               "search": ["type": "string", "description": "Optional text to find in saved post fields."],
                                               "includeArchived": ["type": "boolean", "description": "Include archived posts; false by default."],
                                               "offset": ["type": "integer", "minimum": 0],
                                               "limit": ["type": "integer", "minimum": 1, "maximum": 100]],
                                "required": ["accountID"]]
            ],
            [
                "name": "iris_get_post",
                "description": "Read one saved planner post, including its exact saved details and attachment metadata. This is read-only and never returns binary media bodies.",
                "inputSchema": ["type": "object",
                                "properties": ["accountID": ["type": "string"], "id": ["type": "string", "description": "The post UUID."]],
                                "required": ["accountID", "id"]]
            ],
            [
                "name": "iris_find_duplicate_posts",
                "description": "Find candidate duplicate groups among active saved planner posts. Candidates share normalized title, platform and format; they are not proven duplicates and no post is selected or changed.",
                "inputSchema": ["type": "object", "properties": ["accountID": ["type": "string"]], "required": ["accountID"]]
            ],
            [
                "name": "iris_propose_archive_posts",
                "description": "Queue an archive proposal for explicit in-app review. Pass the current account ID, a new operation UUID, each target's id and revision, and a reason. It validates a snapshot no older than five minutes. It never archives or deletes directly; Iris must approve each request.",
                "inputSchema": ["type": "object",
                                "properties": ["accountID": ["type": "string"], "operationID": ["type": "string", "description": "A UUID retained for safe retries."],
                                               "posts": ["type": "array", "minItems": 1, "maxItems": 100,
                                                         "items": ["type": "object", "properties": ["id": ["type": "string"], "revision": ["type": "string"]], "required": ["id", "revision"]]],
                                               "reason": ["type": "string"]],
                                "required": ["accountID", "operationID", "posts", "reason"]]
            ]
        ]
    }

    // MARK: - Tool calls

    private func call(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "iris_get_workspace_context":
                return Self.text(Self.describe(try client.context()))
            case "iris_submit_post":
                let submission = try client.submit(kind: .post, post: try Self.post(from: arguments), series: nil,
                                                   agent: state.agent, note: Self.string(arguments["note"]), revisionOf: nil)
                return Self.text("Sent to Iris for review. (id: \(submission.id))")
            case "iris_submit_series":
                let submission = try client.submit(kind: .series, post: nil, series: try Self.series(from: arguments),
                                                   agent: state.agent, note: Self.string(arguments["note"]), revisionOf: nil)
                return Self.text("Sent to Iris for review. (id: \(submission.id))")
            case "iris_list_submissions":
                let status = Self.string(arguments["status"]) == "all" ? "all" : "pending"
                return Self.text(Self.list(try client.listSubmissions(status: status)))
            case "iris_revise_submission":
                return try revise(arguments)
            case "iris_list_posts":
                return try listPosts(arguments)
            case "iris_get_post":
                return try getPost(arguments)
            case "iris_find_duplicate_posts":
                return try duplicatePosts(arguments)
            case "iris_propose_archive_posts":
                return try proposeArchive(arguments)
            default:
                return Self.failure("iris-bridge has no tool called \(name).")
            }
        } catch {
            return Self.failure(Self.message(for: error))
        }
    }

    /// A revision is checked against what the helper actually holds before it is sent. Submitting a revision
    /// of an id nobody has ever seen would be accepted and would sit in the Inbox pointing at nothing, so the
    /// agent hears about its typo here instead.
    private func revise(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = Self.string(arguments["id"]) ?? ""
        guard InboxStore.isSubmissionID(id) else { return Self.failure("That submission id is not valid.") }
        let post = arguments["post"] as? [String: Any]
        let series = arguments["series"] as? [String: Any]
        guard post != nil || series != nil else { return Self.failure("Add a post or a series to the revision.") }
        // Both at once used to be sent as a post that also carried a series, and the series went in without
        // ever being measured: the length check runs on whichever side the kind names. A revision is one
        // thing being replaced by one thing, so the agent is asked which — before any round trip.
        guard post == nil || series == nil else { return Self.failure("Send either a post or a series, not both.") }
        guard try client.listSubmissions(status: "all").contains(where: { $0.id == id }) else {
            return Self.failure("That submission was not found.")
        }
        let kind: SubmissionKind = post != nil ? .post : .series
        let submission = try client.submit(kind: kind,
                                           post: kind == .post ? try Self.post(from: post ?? [:]) : nil,
                                           series: kind == .series ? try Self.series(from: series ?? [:]) : nil,
                                           agent: state.agent, note: Self.string(arguments["note"]), revisionOf: id)
        if submission.status == .pending {
            return Self.text("Sent to Iris for review. (id: \(submission.id))")
        }
        return Self.text("Revision already exists with status \(submission.status.rawValue). (id: \(submission.id))")
    }

    // MARK: - Planner cleanup tools

    private func plannerSnapshot(accountID text: String) throws -> PlannerSnapshot {
        guard let accountID = UUID(uuidString: text) else { throw BridgeError.message("That account id is not valid.") }
        guard let snapshot = try client.context().planner else {
            throw BridgeError.message("This Iris app has not shared a planner snapshot yet. Open Iris and refresh the planner, then try again.")
        }
        guard snapshot.schemaVersion == PlannerSnapshot.schemaVersion else {
            throw BridgeError.message("This planner snapshot uses an unsupported schema. Update Iris and Iris Bridge, then try again.")
        }
        guard snapshot.accountID == accountID else { throw BridgeError.message("That account does not match the current planner snapshot.") }
        return snapshot
    }

    private func listPosts(_ arguments: [String: Any]) throws -> [String: Any] {
        let snapshot = try plannerSnapshot(accountID: Self.required(arguments["accountID"], named: "account id"))
        let includeArchived = arguments["includeArchived"] as? Bool ?? false
        let offset = try Self.nonnegative(arguments["offset"], named: "offset", defaultValue: 0)
        let limit = try Self.limit(arguments["limit"])
        let search = Self.string(arguments["search"])?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let matching = snapshot.posts.sorted { $0.id.uuidString < $1.id.uuidString }.filter { post in
            (includeArchived || !post.archived) && (search == nil || Self.searchable(post).contains(search!))
        }
        guard offset <= matching.count else { throw BridgeError.message("That offset is past the end of the matching posts.") }
        let end = min(matching.count, offset + limit)
        let page = matching[offset..<end].map(Self.summary)
        return Self.json(["snapshot": Self.snapshotMetadata(snapshot), "stale": Self.isStale(snapshot),
                          "posts": page, "offset": offset, "limit": limit, "total": matching.count,
                          "nextOffset": end < matching.count ? end : NSNull()])
    }

    private func getPost(_ arguments: [String: Any]) throws -> [String: Any] {
        let snapshot = try plannerSnapshot(accountID: Self.required(arguments["accountID"], named: "account id"))
        let idText = try Self.required(arguments["id"], named: "post id")
        guard let id = UUID(uuidString: idText) else {
            throw BridgeError.message("That post id is not valid.")
        }
        guard let post = snapshot.posts.first(where: { $0.id == id }) else { throw BridgeError.message("That post was not found in the current planner snapshot.") }
        return Self.json(["snapshot": Self.snapshotMetadata(snapshot), "stale": Self.isStale(snapshot), "post": try Self.object(post)])
    }

    private func duplicatePosts(_ arguments: [String: Any]) throws -> [String: Any] {
        let snapshot = try plannerSnapshot(accountID: Self.required(arguments["accountID"], named: "account id"))
        let groups = Dictionary(grouping: snapshot.posts.filter { !$0.archived && Self.duplicateKey($0) != nil }, by: Self.duplicateKey)
            .compactMap { key, posts -> [String: Any]? in
                guard let key, posts.count > 1 else { return nil }
                let ordered = posts.sorted { $0.id.uuidString < $1.id.uuidString }
                return ["id": key, "title": ordered[0].title, "posts": ordered.map(Self.summary)]
            }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return Self.json(["snapshot": Self.snapshotMetadata(snapshot), "stale": Self.isStale(snapshot), "candidates": groups])
    }

    private func proposeArchive(_ arguments: [String: Any]) throws -> [String: Any] {
        let accountText = try Self.required(arguments["accountID"], named: "account id")
        let operationText = try Self.required(arguments["operationID"], named: "operation id")
        guard let accountID = UUID(uuidString: accountText), let operationID = UUID(uuidString: operationText) else {
            throw BridgeError.message("That account id or operation id is not valid.")
        }
        guard let rawTargets = arguments["posts"] as? [[String: Any]] else { throw BridgeError.message("Add one or more archive targets.") }
        let targets = try rawTargets.map { item -> ArchiveTarget in
            let idText = try Self.required(item["id"], named: "target post id")
            guard let id = UUID(uuidString: idText) else { throw BridgeError.message("That target post id is not valid.") }
            return ArchiveTarget(id: id, revision: try Self.required(item["revision"], named: "target revision"))
        }
        let proposal = ArchiveProposal(accountID: accountID, operationID: operationID, posts: targets,
                                       reason: try Self.required(arguments["reason"], named: "archive reason"))
        try SubmissionValidation.validate(archive: proposal)
        // Retries are a read of the persisted operation, not a new proposal. The app may already have
        // archived its targets or the snapshot may have aged out after the first successful queue, and both
        // must still return the original submission and its final status without sending a second request.
        if let existing = try client.listSubmissions(status: "all").first(where: { $0.archive?.operationID == operationID }) {
            guard existing.archive == proposal else {
                throw BridgeError.message("That operation id was already used for a different archive request.")
            }
            return Self.json(["idempotentRetry": true, "submission": try Self.object(existing)])
        }
        let snapshot = try plannerSnapshot(accountID: accountText)
        guard !Self.isStale(snapshot) else { throw BridgeError.message("The planner snapshot is over five minutes old. Refresh Iris before proposing an archive.") }
        for target in targets {
            guard let post = snapshot.posts.first(where: { $0.id == target.id }) else { throw BridgeError.message("An archive target is not in the current planner snapshot.") }
            guard !post.archived else { throw BridgeError.message("An archive target is already archived.") }
            guard post.revision == target.revision else { throw BridgeError.message("An archive target changed. Compare the current post and make a new proposal.") }
        }
        let submission = try client.submitArchive(proposal, agent: state.agent)
        return Self.json(["snapshot": Self.snapshotMetadata(snapshot), "submission": try Self.object(submission)])
    }

    private static func text(_ body: String) -> [String: Any] {
        ["content": [["type": "text", "text": body]], "isError": false]
    }

    private static func failure(_ body: String) -> [String: Any] {
        ["content": [["type": "text", "text": body]], "isError": true]
    }

    /// Tool errors are plain sentences the agent can act on, never stack traces or status codes. "Not
    /// running" is the one case worded for the agent rather than for the person in Terminal.
    private static func message(for error: Error) -> String {
        if error is AdminClientError { return notRunning }
        let sentence = error.localizedDescription
        return sentence.isEmpty ? "Iris Bridge could not do that." : sentence
    }

    // MARK: - Arguments

    /// A string exactly as supplied, or `nil` when the key is missing or explicitly empty. Imported writing
    /// can use leading/trailing whitespace as meaningful formatting.
    private static func string(_ any: Any?) -> String? {
        guard let text = any as? String else { return nil }
        return text.isEmpty ? nil : text
    }

    /// Required fields are passed through as they were given, empty string and all: the helper owns the
    /// "Give the post a title." sentences, and rewording them here would put two different messages in front
    /// of the same mistake.
    private static func required(_ any: Any?) -> String { (any as? String) ?? "" }

    private static func required(_ any: Any?, named name: String) throws -> String {
        guard let value = any as? String, !value.isEmpty else { throw BridgeError.message("Give the \(name).") }
        return value
    }

    private static func nonnegative(_ any: Any?, named name: String, defaultValue: Int) throws -> Int {
        guard let any, !(any is NSNull) else { return defaultValue }
        guard let value = any as? NSNumber, !isBoolean(any), value.intValue >= 0, Double(value.intValue) == value.doubleValue else {
            throw BridgeError.message("Give \(name) as a non-negative whole number.")
        }
        return value.intValue
    }

    private static func limit(_ any: Any?) throws -> Int {
        let value = try nonnegative(any, named: "limit", defaultValue: 50)
        guard value > 0 && value <= 100 else { throw BridgeError.message("Give limit as a whole number from 1 to 100.") }
        return value
    }

    /// An optional whole number. A model that writes `"episode": "3"` is told so rather than having it
    /// dropped: a post that quietly lost its episode number lands in the Inbox belonging to no slot, and
    /// neither the agent nor the creator can see where it went.
    private static func integer(_ any: Any?, _ sentence: String) throws -> Int? {
        guard let any, !(any is NSNull) else { return nil }
        guard let number = any as? NSNumber, !isBoolean(any) else { throw BridgeError.message(sentence) }
        return number.intValue
    }

    /// JSON `true` bridges to `NSNumber` like any other number, and `true` is not an episode.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func post(from arguments: [String: Any]) throws -> SubmittedPost {
        SubmittedPost(title: required(arguments["title"]), pillar: required(arguments["pillar"]),
                      platform: required(arguments["platform"]), format: required(arguments["format"]),
                      postingDate: string(arguments["postingDate"]), hook: string(arguments["hook"]),
                      script: string(arguments["script"]), scenes: try scenes(arguments["scenes"]),
                      caption: string(arguments["caption"]), cta: string(arguments["cta"]),
                      notes: string(arguments["notes"]), seriesName: string(arguments["seriesName"]),
                      episode: try integer(arguments["episode"], "Give episode as a number."))
    }

    private static let sceneSentence = "Each scene needs script and shotNotes text."

    /// Scenes written as bare strings, or missing half of themselves, used to fail one cast and disappear:
    /// the post arrived with no scenes at all and nothing said why.
    private static func scenes(_ any: Any?) throws -> [SubmittedScene]? {
        guard let any, !(any is NSNull) else { return nil }
        guard let elements = any as? [Any] else { throw BridgeError.message(sceneSentence) }
        return try elements.map { element in
            guard let scene = element as? [String: Any],
                  let script = scene["script"] as? String,
                  let shotNotes = scene["shotNotes"] as? String else {
                throw BridgeError.message(sceneSentence)
            }
            return SubmittedScene(script: script, shotNotes: shotNotes)
        }
    }

    static func series(from arguments: [String: Any]) throws -> SubmittedSeries {
        let episodes = try (arguments["episodes"] as? [[String: Any]] ?? []).enumerated().map { index, raw in
            SubmittedEpisode(number: (raw["number"] as? NSNumber)?.intValue ?? index + 1,
                             date: string(raw["date"]),
                             post: try post(from: raw["post"] as? [String: Any] ?? [:]))
        }
        return SubmittedSeries(name: required(arguments["name"]), pillar: required(arguments["pillar"]),
                               summary: string(arguments["summary"]), episodes: episodes)
    }

    // MARK: - Planner rendering

    private static func snapshotMetadata(_ snapshot: PlannerSnapshot) -> [String: Any] {
        ["schemaVersion": snapshot.schemaVersion, "accountID": snapshot.accountID.uuidString,
         "revision": snapshot.revision, "capturedAt": ISO8601DateFormatter().string(from: snapshot.capturedAt)]
    }

    private static func summary(_ post: PlannerPost) -> [String: Any] {
        ["id": post.id.uuidString, "revision": post.revision, "title": post.title,
         "platform": post.platform, "format": post.format, "archived": post.archived]
    }

    private static func isStale(_ snapshot: PlannerSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        return age < 0 || age > 5 * 60
    }

    private static func searchable(_ post: PlannerPost) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let details = (try? encoder.encode(post.details)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (post.title + "\n" + post.platform + "\n" + post.format + "\n" + details)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func duplicateKey(_ post: PlannerPost) -> String? {
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let parts = [normalized(post.title), normalized(post.platform), normalized(post.format)]
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "\u{1F}")
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private static func json(_ object: [String: Any]) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return failure("Iris Bridge could not write that planner response.") }
        return Self.text(text)
    }

    // MARK: - Rendering

    static func list(_ submissions: [Submission]) -> String {
        guard !submissions.isEmpty else { return "Nothing has been sent yet." }
        // One submission, one line. Titles and comments are written elsewhere — by the agent, or by the
        // creator on a phone — so they are flattened before they are printed: see `OneLineText`.
        return submissions.map { submission in
            var line = "\(submission.id) · \(submission.kind.rawValue) · \(submission.listTitle) · \(submission.status.rawValue)"
            if let raw = string(submission.comment) {
                let comment = OneLineText.clean(raw)
                if !comment.isEmpty { line += " · \(comment)" }
            }
            return line
        }.joined(separator: "\n")
    }

    private static let weekdayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func describe(_ context: WorkspaceContext) -> String {
        var lines = ["Creator: \(context.creatorName)", ""]
        lines.append("Pillars")
        if context.pillars.isEmpty { lines.append("- none yet") }
        for pillar in context.pillars {
            let days = pillar.weekdays.map { weekdayNames.indices.contains($0) ? weekdayNames[$0] : "\($0)" }
            var line = "- \(pillar.name)"
            if pillar.isAnchor { line += " (anchor)" }
            if let detail = string(pillar.detail) { line += " — \(detail)" }
            if !days.isEmpty { line += " — usual days: \(days.joined(separator: ", "))" }
            lines.append(line)
        }
        lines.append("")
        lines.append("Platforms")
        if context.platforms.isEmpty { lines.append("- none yet") }
        for platform in context.platforms {
            lines.append("- \(platform.name) — formats: \(platform.formats.isEmpty ? "none" : platform.formats.joined(separator: ", ")) — \(platform.weeklyGoal) a week")
        }
        lines.append("")
        lines.append("Series")
        if context.series.isEmpty { lines.append("- none yet") }
        for series in context.series {
            lines.append("- \(series.name) (\(series.pillar)) — \(series.episodes.count) episode\(series.episodes.count == 1 ? "" : "s")")
            for episode in series.episodes {
                let parts = [episode.date, episode.title, episode.filled ? "filled" : "empty"].compactMap { $0 }
                lines.append("  \(episode.number). \(parts.joined(separator: " · "))")
            }
        }
        if let creatorContext = string(context.creatorContext) {
            lines.append("")
            lines.append("Creator context")
            lines.append(creatorContext)
        }
        return lines.joined(separator: "\n")
    }
}
