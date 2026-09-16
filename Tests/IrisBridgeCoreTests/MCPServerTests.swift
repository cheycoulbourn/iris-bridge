import XCTest
@testable import IrisBridgeCore

/// The MCP server is the only part of the helper an agent talks to directly, and it never sees the network:
/// every call goes back through loopback to the running helper. So it is tested against a fake client, which
/// is also the only way to make "the helper is not running" happen on purpose.
private final class FakeAdminClient: AdminClientProtocol {
    var stored: [Submission] = []
    var workspace: WorkspaceContext?
    var submitFailure: Error?
    var listFailure: Error?
    var contextFailure: Error?
    var lastSubmit: (kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?, agent: String, note: String?, revisionOf: String?)?
    var listedStatuses: [String] = []

    func submit(kind: SubmissionKind, post: SubmittedPost?, series: SubmittedSeries?,
                agent: String, note: String?, revisionOf: String?) throws -> Submission {
        lastSubmit = (kind, post, series, agent, note, revisionOf)
        if let submitFailure { throw submitFailure }
        let submission = Submission(id: "sub_abcdef123456", kind: kind, post: post, series: series,
                                    agent: agent, note: note, createdAt: Date(), revisionOf: revisionOf)
        stored.insert(submission, at: 0)
        return submission
    }

    func listSubmissions(status: String) throws -> [Submission] {
        listedStatuses.append(status)
        if let listFailure { throw listFailure }
        return stored
    }

    func context() throws -> WorkspaceContext {
        if let contextFailure { throw contextFailure }
        guard let workspace else { throw BridgeError.message("No workspace context yet. Open Iris on a paired device.") }
        return workspace
    }
}

final class MCPServerTests: XCTestCase {
    private var client: FakeAdminClient!
    private var server: MCPServer!

    override func setUp() {
        client = FakeAdminClient()
        server = MCPServer(client: client, version: "0.2.0")
    }

    // MARK: - Helpers

    private func reply(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let data = server.handle(Data(json.utf8)) else {
            XCTFail("expected a reply to \(json)", file: file, line: line); return [:]
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("reply was not a JSON object", file: file, line: line); return [:]
        }
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0", file: file, line: line)
        return object
    }

    private func result(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let object = reply(json, file: file, line: line)
        guard let result = object["result"] as? [String: Any] else {
            XCTFail("expected a result, got \(object)", file: file, line: line); return [:]
        }
        return result
    }

    private func call(_ name: String, _ arguments: String = "{}", file: StaticString = #filePath, line: UInt = #line) -> (text: String, isError: Bool) {
        let request = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        let result = self.result(request, file: file, line: line)
        let content = (result["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text", file: file, line: line)
        return (content?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    private let samplePost = #"{"title":"Three shots","pillar":"Craft","platform":"Instagram","format":"Reel","hook":"Do this once"}"#

    // MARK: - Protocol

    func testInitializeAnnouncesTheToolsCapabilityAndVersion() {
        let result = self.result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"1.0"}}}"#)
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any])
        let info = result["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "iris-bridge")
        XCTAssertEqual(info?["version"] as? String, "0.2.0")
    }

    func testPingAnswersWithAnEmptyResult() {
        XCTAssertTrue(result(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#).isEmpty)
    }

    func testNotificationsGetNoReplyAtAll() {
        XCTAssertNil(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        XCTAssertNil(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8)))
    }

    func testUnknownMethodIsMethodNotFound() {
        let error = reply(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
        XCTAssertTrue((error?["message"] as? String ?? "").contains("resources/list"))
    }

    /// A half-written line is the one failure the transport cannot hide, and JSON-RPC says it answers with a
    /// null id because there is no id to answer with.
    func testMalformedJSONIsAParseErrorWithANullID() {
        let object = reply("{not json")
        XCTAssertTrue(object["id"] is NSNull, "expected a null id, got \(String(describing: object["id"]))")
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testTheRequestIDIsEchoedWithItsOwnType() {
        XCTAssertEqual(reply(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)["id"] as? String, "abc")
        XCTAssertEqual(reply(#"{"jsonrpc":"2.0","id":11,"method":"ping"}"#)["id"] as? Int, 11)
    }

    // MARK: - tools/list

    func testToolsListHasTheFiveToolsWithSchemas() {
        let tools = result(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.map { $0["name"] as? String },
                       ["iris_get_workspace_context", "iris_submit_post", "iris_submit_series",
                        "iris_list_submissions", "iris_revise_submission"])
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(tool["name"] ?? "?") needs an object schema")
            XCTAssertNotNil(schema?["properties"] as? [String: Any], "\(tool["name"] ?? "?") needs properties")
            XCTAssertNotNil(schema?["required"] as? [String], "\(tool["name"] ?? "?") needs a required array")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in (tool["name"] as? String).map { ($0, tool) } })
        XCTAssertEqual((byName["iris_submit_post"]?["inputSchema"] as? [String: Any])?["required"] as? [String],
                       ["title", "pillar", "platform", "format"])
        XCTAssertEqual((byName["iris_submit_series"]?["inputSchema"] as? [String: Any])?["required"] as? [String],
                       ["name", "pillar", "episodes"])
        XCTAssertEqual((byName["iris_revise_submission"]?["inputSchema"] as? [String: Any])?["required"] as? [String], ["id"])
        XCTAssertEqual((byName["iris_get_workspace_context"]?["inputSchema"] as? [String: Any])?["required"] as? [String], [])
    }

    /// The descriptions are the only instructions the agent gets, so the four rules the spec names are
    /// asserted rather than trusted to survive an edit.
    func testDescriptionsCarryTheRulesTheAgentMustFollow() {
        let tools = result(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)["tools"] as? [[String: Any]] ?? []
        let submitters = tools.filter { ($0["name"] as? String ?? "").hasPrefix("iris_submit") || ($0["name"] as? String) == "iris_revise_submission" }
        XCTAssertEqual(submitters.count, 3)
        for tool in submitters {
            let description = tool["description"] as? String ?? ""
            XCTAssertTrue(description.contains("iris_get_workspace_context"), "\(tool["name"] ?? "?"): \(description)")
            XCTAssertTrue(description.contains("already exist"), "\(tool["name"] ?? "?"): \(description)")
            XCTAssertTrue(description.contains("15 words"), "\(tool["name"] ?? "?"): \(description)")
            XCTAssertTrue(description.contains("Nothing is saved until"), "\(tool["name"] ?? "?"): \(description)")
        }
    }

    // MARK: - tools/call

    func testSubmitPostSendsItToTheHelperAndConfirmsWithTheID() {
        let (text, isError) = call("iris_submit_post", #"{"title":"Three shots","pillar":"Craft","platform":"Instagram","format":"Reel","hook":"Do this once","scenes":[{"script":"open","shotNotes":"wide"}],"note":"Ready for you."}"#)
        XCTAssertFalse(isError)
        XCTAssertEqual(text, "Sent to Iris for review. (id: sub_abcdef123456)")
        XCTAssertEqual(client.lastSubmit?.kind, .post)
        XCTAssertEqual(client.lastSubmit?.post?.title, "Three shots")
        XCTAssertEqual(client.lastSubmit?.post?.scenes?.first?.shotNotes, "wide")
        XCTAssertEqual(client.lastSubmit?.note, "Ready for you.")
        XCTAssertNil(client.lastSubmit?.revisionOf)
    }

    func testSubmitSeriesCarriesEveryEpisode() {
        let arguments = #"{"name":"Quiet mornings","pillar":"Craft","summary":"Four calm ones","episodes":[{"number":1,"date":"2026-09-20","post":\#(samplePost)},{"number":2,"post":\#(samplePost)}]}"#
        let (text, isError) = call("iris_submit_series", arguments)
        XCTAssertFalse(isError, text)
        XCTAssertEqual(client.lastSubmit?.kind, .series)
        XCTAssertEqual(client.lastSubmit?.series?.episodes.count, 2)
        XCTAssertEqual(client.lastSubmit?.series?.episodes.first?.date, "2026-09-20")
        XCTAssertEqual(client.lastSubmit?.series?.name, "Quiet mornings")
    }

    /// The helper validates, not the MCP layer, so the creator-facing sentence comes back untouched.
    func testAValidationFailureBecomesAToolErrorWithTheSentence() {
        client.submitFailure = BridgeError.message("Give the post a title.")
        let (text, isError) = call("iris_submit_post", #"{"pillar":"Craft","platform":"Instagram","format":"Reel"}"#)
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "Give the post a title.")
    }

    func testAHelperThatIsNotRunningSaysSoInTheToolResult() {
        client.submitFailure = AdminClientError.notRunning
        let (text, isError) = call("iris_submit_post", samplePost)
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "Iris Bridge is not running. Run `iris-bridge status` on this Mac.")
    }

    func testAnUnknownToolIsAToolErrorNotAProtocolError() {
        let (text, isError) = call("iris_publish_everywhere")
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("iris_publish_everywhere"), text)
    }

    func testTheAgentNameComesFromTheClientThatConnected() {
        _ = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code","version":"1.0"}}}"#)
        _ = call("iris_submit_post", samplePost)
        XCTAssertEqual(client.lastSubmit?.agent, "claude-code")
    }

    func testWithoutAnInitializeTheAgentIsStillNamedSomething() {
        _ = call("iris_submit_post", samplePost)
        XCTAssertEqual(client.lastSubmit?.agent, "agent")
    }

    // MARK: - Listing

    func testListSubmissionsPrintsOneLinePerSubmissionNewestFirst() throws {
        let older = Submission(id: "sub_aaaaaaaaaaaa", kind: .post,
                               post: SubmittedPost(title: "Older", pillar: "Craft", platform: "Instagram", format: "Reel"),
                               agent: "claude", status: .changesRequested, comment: "tighten the hook",
                               createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Submission(id: "sub_bbbbbbbbbbbb", kind: .series,
                               series: SubmittedSeries(name: "Quiet mornings", pillar: "Craft", episodes: []),
                               agent: "claude", status: .pending, createdAt: Date(timeIntervalSince1970: 2_000))
        client.stored = [newer, older]
        let (text, isError) = call("iris_list_submissions", #"{"status":"all"}"#)
        XCTAssertFalse(isError)
        XCTAssertEqual(text, """
        sub_bbbbbbbbbbbb · series · Quiet mornings · pending
        sub_aaaaaaaaaaaa · post · Older · changesRequested · tighten the hook
        """)
        XCTAssertEqual(client.listedStatuses, ["all"])
    }

    func testListSubmissionsDefaultsToPendingAndSaysWhenNothingIsThere() {
        let (text, isError) = call("iris_list_submissions")
        XCTAssertFalse(isError)
        XCTAssertEqual(text, "Nothing has been sent yet.")
        XCTAssertEqual(client.listedStatuses, ["pending"])
    }

    // MARK: - Context

    func testWorkspaceContextIsRenderedAsSomethingAnAgentCanRead() {
        client.workspace = WorkspaceContext(creatorName: "Chey",
                                          pillars: [ContextPillar(name: "Craft", detail: "How it is made", isAnchor: true, weekdays: [2, 4])],
                                          platforms: [ContextPlatform(name: "Instagram", formats: ["Reel", "Carousel"], weeklyGoal: 3)],
                                          series: [ContextSeries(name: "Quiet mornings", pillar: "Craft",
                                                                 episodes: [ContextEpisode(number: 1, date: "2026-09-20", title: "One", filled: true)])],
                                          creatorContext: "Speaks plainly.", updatedAt: Date())
        let (text, isError) = call("iris_get_workspace_context")
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("Chey"), text)
        XCTAssertTrue(text.contains("Craft"), text)
        XCTAssertTrue(text.contains("anchor"), text)
        XCTAssertTrue(text.contains("Instagram"), text)
        XCTAssertTrue(text.contains("Reel"), text)
        XCTAssertTrue(text.contains("Quiet mornings"), text)
        XCTAssertTrue(text.contains("Speaks plainly."), text)
    }

    func testNoContextYetIsAToolErrorWithTheSentenceFromTheHelper() {
        let (text, isError) = call("iris_get_workspace_context")
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "No workspace context yet. Open Iris on a paired device.")
    }

    // MARK: - Revisions

    func testRevisingSomethingTheHelperHasNeverSeenIsRefusedBeforeItIsSubmitted() {
        client.stored = []
        let (text, isError) = call("iris_revise_submission", #"{"id":"sub_abcdef123456","post":\#(samplePost)}"#)
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "That submission was not found.")
        XCTAssertNil(client.lastSubmit, "the revision must not reach the helper")
    }

    func testRevisingWithAnIDThatIsNotAnIDIsRefusedWithoutAskingTheHelper() {
        let (text, isError) = call("iris_revise_submission", #"{"id":"42","post":\#(samplePost)}"#)
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "That submission id is not valid.")
        XCTAssertTrue(client.listedStatuses.isEmpty)
    }

    func testARevisionOfAKnownSubmissionCarriesRevisionOf() {
        client.stored = [Submission(id: "sub_aaaaaaaaaaaa", kind: .post,
                                    post: SubmittedPost(title: "Older", pillar: "Craft", platform: "Instagram", format: "Reel"),
                                    agent: "claude", createdAt: Date())]
        let (text, isError) = call("iris_revise_submission", #"{"id":"sub_aaaaaaaaaaaa","post":\#(samplePost),"note":"Shorter hook."}"#)
        XCTAssertFalse(isError, text)
        XCTAssertEqual(text, "Sent to Iris for review. (id: sub_abcdef123456)")
        XCTAssertEqual(client.lastSubmit?.revisionOf, "sub_aaaaaaaaaaaa")
        XCTAssertEqual(client.lastSubmit?.note, "Shorter hook.")
        XCTAssertEqual(client.listedStatuses, ["all"])
    }

    func testARevisionWithNeitherAPostNorASeriesSaysWhatIsMissing() {
        client.stored = [Submission(id: "sub_aaaaaaaaaaaa", kind: .post, agent: "claude", createdAt: Date())]
        let (text, isError) = call("iris_revise_submission", #"{"id":"sub_aaaaaaaaaaaa"}"#)
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "Add a post or a series to the revision.")
    }

    // MARK: - Transport

    /// Claude Code writes one JSON object per line and may hand over two in a single read; a transport that
    /// reads "a chunk" rather than "a line" would lose the second one.
    func testNewlineFramingRoundTripsTwoMessagesDeliveredInOneWrite() throws {
        let input = Pipe(), output = Pipe()
        let transport = StdioMCPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try input.fileHandleForWriting.write(contentsOf: Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        try input.fileHandleForWriting.close()
        XCTAssertEqual(try transport.readMessage().map { String(decoding: $0, as: UTF8.self) }, "{\"a\":1}")
        XCTAssertEqual(try transport.readMessage().map { String(decoding: $0, as: UTF8.self) }, "{\"b\":2}")
        XCTAssertNil(try transport.readMessage())
        try transport.writeMessage(Data("{\"ok\":true}".utf8))
        try output.fileHandleForWriting.close()
        let written = try output.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertEqual(String(decoding: written, as: UTF8.self), "{\"ok\":true}\n")
    }

    /// Blank lines between messages are framing noise, not a parse error: answering -32700 to one would send
    /// an unsolicited error to a client that asked nothing.
    func testBlankLinesAreSkippedAndATrailingLineWithoutANewlineStillArrives() throws {
        let input = Pipe(), output = Pipe()
        let transport = StdioMCPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try input.fileHandleForWriting.write(contentsOf: Data("\n\n{\"a\":1}\r\n{\"b\":2}".utf8))
        try input.fileHandleForWriting.close()
        XCTAssertEqual(try transport.readMessage().map { String(decoding: $0, as: UTF8.self) }, "{\"a\":1}")
        XCTAssertEqual(try transport.readMessage().map { String(decoding: $0, as: UTF8.self) }, "{\"b\":2}")
        XCTAssertNil(try transport.readMessage())
    }

    /// `run` is the whole loop: everything in, every answer out, notifications silent.
    func testRunAnswersEveryRequestAndStaysQuietForNotifications() throws {
        let input = Pipe(), output = Pipe()
        let transport = StdioMCPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let script = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}

        """
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        try server.run(transport: transport)
        try output.fileHandleForWriting.close()
        let lines = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "one reply per request and nothing for the notification")
        XCTAssertTrue(lines[1].contains("iris_submit_post"), String(lines[1]))
    }

    // MARK: - CLI formatting

    func testSubmissionAgeReadsAsMinutesHoursOrDays() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        func age(_ seconds: TimeInterval) -> String {
            Submission(id: "sub_aaaaaaaaaaaa", kind: .post, agent: "claude",
                       createdAt: now.addingTimeInterval(-seconds)).ageText(now: now)
        }
        XCTAssertEqual(age(30), "0m")
        XCTAssertEqual(age(3 * 60), "3m")
        XCTAssertEqual(age(2 * 60 * 60), "2h")
        XCTAssertEqual(age(26 * 60 * 60), "1d")
    }

    func testSubmissionTitleFallsBackToTheSeriesNameThenToTheKind() {
        XCTAssertEqual(Submission(id: "sub_aaaaaaaaaaaa", kind: .post,
                                  post: SubmittedPost(title: "Three shots", pillar: "Craft", platform: "Instagram", format: "Reel"),
                                  agent: "claude", createdAt: Date()).displayTitle, "Three shots")
        XCTAssertEqual(Submission(id: "sub_aaaaaaaaaaaa", kind: .series,
                                  series: SubmittedSeries(name: "Quiet mornings", pillar: "Craft", episodes: []),
                                  agent: "claude", createdAt: Date()).displayTitle, "Quiet mornings")
        XCTAssertEqual(Submission(id: "sub_aaaaaaaaaaaa", kind: .post, agent: "claude", createdAt: Date()).displayTitle, "Untitled post")
    }
}
