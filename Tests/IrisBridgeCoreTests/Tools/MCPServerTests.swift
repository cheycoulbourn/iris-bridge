import XCTest
@testable import IrisBridgeCore

/// The MCP server is a thin proxy: it lists the Iris tools and forwards every call to the running helper over
/// loopback. So it is tested against a fake client, which is also the only way to make "the helper is not
/// running" happen on purpose. What the tools do is tested in `ToolServiceTests` and the read and change tests.
private final class FakeToolClient: ToolCalling {
    var calls: [(name: String, arguments: JSONValue, threadId: String?, turnId: String, agent: String)] = []
    var failure: Error?
    var answer: JSONValue = ["content": [["type": "text", "text": "ok"]], "isError": false]
    var delay: TimeInterval = 0
    private let lock = NSLock()

    func call(name: String, arguments: JSONValue, threadId: String?, turnId: String, agent: String) throws -> JSONValue {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); calls.append((name, arguments, threadId, turnId, agent)); lock.unlock()
        if let failure { throw failure }
        return answer
    }
}

final class MCPServerTests: XCTestCase {
    private var client: FakeToolClient!
    private var server: MCPServer!

    override func setUp() {
        client = FakeToolClient()
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
        let result = self.result(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#, file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    private func toolNames() -> [String] {
        ((result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    // MARK: - Protocol

    func testInitializeAnnouncesTheToolsCapabilityAndVersion() {
        let result = self.result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"1.0"}}}"#)
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any])
        let info = result["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "iris-bridge")
        XCTAssertEqual(info?["version"] as? String, "0.2.0")
    }

    /// MCP negotiation: the reply names a version the server actually speaks. The client's own is echoed when
    /// it is one of them, so a client pinned to the older revision is not told to speak one it cannot.
    func testInitializeEchoesAProtocolVersionTheServerAlsoSpeaks() {
        let result = self.result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"claude-code"}}}"#)
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
    }

    func testAProtocolVersionTheServerDoesNotSpeakGetsTheOneItDoes() {
        XCTAssertEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)["protocolVersion"] as? String,
                       "2025-06-18")
        XCTAssertEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":7}}"#)["protocolVersion"] as? String,
                       "2025-06-18")
        XCTAssertEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)["protocolVersion"] as? String,
                       "2025-06-18")
    }

    /// `iris-bridge mcp` hands stdout to the client. A client that closes it before the last reply is written
    /// would kill the process with SIGPIPE mid-sentence; ignored, the read loop ends at EOF instead.
    func testTheServerIgnoresBrokenPipesSoAClosedStdoutEndsAtEOF() {
        // Signal handlers are function pointers, which are not Equatable; compared as raw addresses instead.
        func address(_ handler: sig_t?) -> UnsafeRawPointer? { unsafeBitCast(handler, to: UnsafeRawPointer?.self) }
        // Put SIGPIPE back to its default first, so this cannot pass on a disposition something else set.
        let original = signal(SIGPIPE, SIG_DFL)
        let afterwards = { () -> sig_t? in
            MCPServer.ignoreBrokenPipe()
            return signal(SIGPIPE, original ?? SIG_DFL)   // reads what it set, and restores what was there
        }()
        XCTAssertEqual(address(afterwards), address(SIG_IGN), "SIGPIPE was left at its default disposition")
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

    // MARK: - tools/list and tools/call

    func testToolsListIsTheVocabularyAndOnlyAChatSessionGetsTheApprovalTool() {
        let names = toolNames()
        XCTAssertEqual(names, IrisToolCatalog.all.map(\.name))
        XCTAssertFalse(names.contains("iris_submit_post"))
        XCTAssertFalse(names.contains("approval"))
        server = MCPServer(client: client, version: "0.3.0", threadId: "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77")
        XCTAssertTrue(toolNames().contains("approval"))
    }

    func testACallGoesToTheHelperWithItsThreadAndAgentAndItsResultComesBack() {
        server = MCPServer(client: client, version: "0.3.0", threadId: "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77")
        client.answer = ["content": [["type": "text", "text": #"{"status":"queued_for_review"}"#]], "isError": false]
        _ = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code","version":"2.1.274"}}}"#)
        let (text, isError) = call("iris_create_task", #"{"title":"Film the intro"}"#)
        XCTAssertEqual(text, #"{"status":"queued_for_review"}"#)
        XCTAssertFalse(isError)
        XCTAssertEqual(client.calls.first?.name, "iris_create_task")
        XCTAssertEqual(client.calls.first?.arguments, ["title": "Film the intro"])
        XCTAssertEqual(client.calls.first?.threadId, "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77")
        XCTAssertEqual(client.calls.first?.agent, "claude")
    }

    func testTheAgentIsNamedAfterTheClientThatConnected() {
        for (clientName, agent) in [("claude-code", "claude"), ("codex-mcp-client", "codex"), ("Cursor", "Cursor")] {
            server = MCPServer(client: client, version: "0.3.0")
            _ = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"\#(clientName)"}}}"#)
            _ = call("iris_list_posts")
            XCTAssertEqual(client.calls.last?.agent, agent, clientName)
        }
        server = MCPServer(client: client, version: "0.3.0")
        _ = call("iris_list_posts")
        XCTAssertEqual(client.calls.last?.agent, "agent", "no initialize still names someone")
    }

    /// The app's batch rule counts per turn; a terminal agent's calls close together count as one.
    func testATerminalAgentsCallsCloseTogetherShareATurn() {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        server = MCPServer(client: client, version: "0.3.0", now: { clock })
        _ = call("iris_create_task", #"{"title":"One"}"#)
        clock = clock.addingTimeInterval(90)
        _ = call("iris_create_task", #"{"title":"Two"}"#)
        clock = clock.addingTimeInterval(121)
        _ = call("iris_create_task", #"{"title":"Three"}"#)
        let turns = client.calls.map(\.turnId)
        XCTAssertTrue(turns[0].hasPrefix("agent-"))
        XCTAssertEqual(turns[0], turns[1])
        XCTAssertNotEqual(turns[1], turns[2])
    }

    /// I7: "not set up", "not running", "not answering" and "wrong certificate" each reach the agent as their own
    /// sentence, because each has a different fix.
    func testEachWayOfNotReachingTheHelperReadsDifferentlyToTheAgent() {
        var seen = Set<String>()
        for failure in [AdminClientError.notInstalled, .notRunning, .timedOut, .certificateMismatch] {
            client.failure = failure
            let (text, isError) = call("iris_workspace_summary")
            XCTAssertTrue(isError)
            XCTAssertEqual(text, failure.agentMessage)
            seen.insert(text)
        }
        XCTAssertEqual(seen.count, 4)
    }

    /// An approval can wait on the owner for minutes; the calls behind it must not wait with it.
    func testASlowCallDoesNotHoldUpTheMessagesBehindIt() throws {
        client.delay = 0.5
        let input = Pipe(), output = Pipe()
        let transport = StdioMCPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let script = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_workspace_summary","arguments":{}}}
        {"jsonrpc":"2.0","id":2,"method":"ping"}

        """
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        try server.run(transport: transport)
        try output.fileHandleForWriting.close()
        let lines = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "run waits for the call in flight before it returns")
        XCTAssertTrue(lines[0].contains(#""id":2"#), "the ping was answered first: \(lines[0])")
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

    /// Claude Code keeps stdin open for the life of the session and expects the reply to `initialize` before
    /// it writes anything else. A read that waited for 64 KB or end of input never answered, so every
    /// connection timed out after 30 s even though the server worked fine when fed a closed file.
    func testAMessageIsReturnedWhileTheInputStaysOpen() throws {
        let input = Pipe(), output = Pipe()
        let transport = StdioMCPTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try input.fileHandleForWriting.write(contentsOf: Data("{\"a\":1}\n".utf8))
        let arrived = expectation(description: "first line read without end of input")
        var message: String?
        Thread.detachNewThread {
            message = (try? transport.readMessage()).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
            arrived.fulfill()
        }
        wait(for: [arrived], timeout: 3)
        XCTAssertEqual(message, "{\"a\":1}")
        try input.fileHandleForWriting.close()
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
        XCTAssertTrue(lines[1].contains("iris_workspace_summary"), String(lines[1]))
    }
}
