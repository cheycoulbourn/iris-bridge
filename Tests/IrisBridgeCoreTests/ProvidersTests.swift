import CryptoKit
import XCTest
@testable import IrisBridgeCore

private final class FakeRunner: ProcessRunner {
    var handler: ([String], String?) throws -> ProcessResult
    var calls: [[String]] = []
    init(_ handler: @escaping ([String], String?) throws -> ProcessResult) { self.handler = handler }
    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        calls.append(args); return try handler(args, input)
    }
}
private func result(_ stdout: String = "", stderr: String = "", status: Int32 = 0) -> ProcessResult { ProcessResult(status: status, stdout: stdout, stderr: stderr) }
private func lines(_ events: [[String: Any]]) -> String {
    events.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
}

final class ProvidersTests: XCTestCase {
    func testSubscriptionEnvironmentStripsKeys() {
        let env = ProviderService.subscriptionEnvironment(from: ["ANTHROPIC_API_KEY": "s", "CLAUDE_CODE_OAUTH_TOKEN": "s", "OPENAI_API_KEY": "s", "PATH": "normal"])
        XCTAssertEqual(env, ["PATH": "normal"])
    }
    func testClaudeStatusRequiresSubscription() {
        let runner = FakeRunner { _, _ in result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai","email":"e@x.com"}"#) }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" })
        XCTAssertTrue(service.status("claude").ready)
        XCTAssertEqual(service.status("claude").auth, "subscription")
        let keyRunner = FakeRunner { _, _ in result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"api_key"}"#) }
        XCTAssertFalse(ProviderService(runner: keyRunner, executableLookup: { _ in "/tool" }).status("claude").ready)
    }
    func testCodexStatusNeedsChatGPT() {
        XCTAssertFalse(ProviderService(runner: FakeRunner { _, _ in result(stderr: "Logged in using an API key") }, executableLookup: { _ in "/tool" }).status("codex").ready)
        XCTAssertTrue(ProviderService(runner: FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }, executableLookup: { _ in "/tool" }).status("codex").ready)
    }
    func testMissingExecutableReportsInstall() {
        let s = ProviderService(runner: FakeRunner { _, _ in result() }, executableLookup: { _ in nil }).status("claude")
        XCTAssertFalse(s.ready); XCTAssertEqual(s.message, "Install Claude Code on your Mac first.")
    }
    func testStatusIsCachedForSixtySeconds() {
        var now = Date(timeIntervalSince1970: 0)
        let runner = FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, now: { now })
        _ = service.status("codex"); _ = service.status("codex")
        XCTAssertEqual(runner.calls.count, 1)
        now = now.addingTimeInterval(61); _ = service.status("codex")
        XCTAssertEqual(runner.calls.count, 2)
    }
    func testClaudeGenerateReportsModelAndBlocksKeyBilling() throws {
        var source = "none"
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "claude-fable-5-1", "apiKeySource": source],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" })
        let output = try service.generate(MessageRequest(provider: "claude", message: "Hello"))
        XCTAssertEqual(output["model"] as? String, "claude-fable-5-1"); XCTAssertEqual(output["auth"] as? String, "subscription")
        source = "env"
        XCTAssertThrowsError(try service.generate(MessageRequest(provider: "claude", message: "Hello"))) { XCTAssertTrue("\($0)".contains("API-key")) }
    }
    func testClaudeUpdateRunsAtMostOncePerHour() throws {
        var now = Date(timeIntervalSince1970: 0)
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": "none"],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, now: { now })
        _ = try service.generate(MessageRequest(provider: "claude", message: "a"))
        _ = try service.generate(MessageRequest(provider: "claude", message: "b"))
        XCTAssertEqual(runner.calls.filter { $0.contains("install") }.count, 1)
        now = now.addingTimeInterval(3601)
        _ = try service.generate(MessageRequest(provider: "claude", message: "c"))
        XCTAssertEqual(runner.calls.filter { $0.contains("install") }.count, 2)
    }
    func testCodexPlanModeSuppressesProposal() throws {
        let reply = #"{"reply":"Ready","proposal":{"title":"No write"}}"#
        let runner = FakeRunner { args, _ in
            if args.contains("login") { return result(stderr: "Logged in using ChatGPT") }
            return result(lines([["type": "item.completed", "item": ["type": "agent_message", "text": reply]], ["type": "turn.completed"]]))
        }
        let output = try ProviderService(runner: runner, executableLookup: { _ in "/tool" }).generate(MessageRequest(provider: "codex", message: "Hi", planMode: true))
        XCTAssertTrue(output["proposal"] is NSNull); XCTAssertEqual(output["auth"] as? String, "subscription")
    }
    func testCanceledRequestDoesNotLaunch() {
        let runner = ForegroundProcessRunner()
        runner.markCanceled("cancel-1")
        XCTAssertThrowsError(try runner.run(["/usr/bin/true"], input: nil, cwd: nil, timeout: 5, requestID: "cancel-1")) { XCTAssertEqual($0 as? BridgeError, .canceled) }
    }

    // MARK: - Fix round 1: verbatim contract with the Python helper

    func testSystemPromptMatchesPythonHelper() {
        XCTAssertEqual(BridgePrompt.system.count, 1501)
        XCTAssertTrue(BridgePrompt.system.hasPrefix("You are Iris, Iris's content planning as"))
        XCTAssertTrue(BridgePrompt.system.hasSuffix("ed; only the creator can decide in Iris."))
        // Derived from the SYSTEM literal in Bridge/iris_bridge.py line 18: the text between its
        // triple-quote delimiters piped through `printf '%s' "$TEXT" | shasum -a 256`.
        let pythonDigest = "cc0981392a8785c5bfa3fa29a6859869d28dbe18845aa81443015ab69d725115"
        let digest = SHA256.hash(data: Data(BridgePrompt.system.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, pythonDigest)
    }

    func testSchemaMatchesPythonHelper() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(BridgePrompt.schemaJSON.utf8)) as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "object")
        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(try XCTUnwrap(root["required"] as? [String])), ["reply", "proposal"])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        XCTAssertEqual((properties["reply"] as? [String: Any])?["type"] as? String, "string")
        let anyOf = try XCTUnwrap((properties["proposal"] as? [String: Any])?["anyOf"] as? [[String: Any]])
        XCTAssertEqual(anyOf.count, 2)
        XCTAssertEqual(anyOf[0]["type"] as? String, "null")
        let proposal = anyOf[1]
        XCTAssertEqual(proposal["type"] as? String, "object")
        XCTAssertEqual(proposal["additionalProperties"] as? Bool, false)
        let required = try XCTUnwrap(proposal["required"] as? [String])
        XCTAssertEqual(required.count, 13)
        XCTAssertEqual(Set(required), ["operation", "targetPostID", "title", "script", "cta", "pillar", "platform",
                                       "format", "postingDate", "scenes", "hook", "caption", "notes"])
        let proposalProperties = try XCTUnwrap(proposal["properties"] as? [String: Any])
        XCTAssertEqual(Set(proposalProperties.keys), Set(required))
        XCTAssertEqual((proposalProperties["operation"] as? [String: Any])?["enum"] as? [String], ["create", "revise"])
        let scenes = try XCTUnwrap(proposalProperties["scenes"] as? [String: Any])
        XCTAssertEqual(scenes["type"] as? String, "array")
        let item = try XCTUnwrap(scenes["items"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "object")
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(try XCTUnwrap(item["required"] as? [String])), ["id", "script", "shotNotes"])
        XCTAssertEqual(Set(try XCTUnwrap(item["properties"] as? [String: Any]).keys), ["id", "script", "shotNotes"])
    }

    func testClaudeArgumentVectorMatchesPython() throws {
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": "none"],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        _ = try ProviderService(runner: runner, executableLookup: { _ in "/tool" }).generate(MessageRequest(provider: "claude", message: "Hello"))
        let main = try XCTUnwrap(runner.calls.first { $0.contains("--json-schema") })
        XCTAssertEqual(main, ["/tool", "-p", "--safe-mode", "--model", "best", "--effort", "medium", "--tools", "",
                              "--permission-mode", "dontAsk", "--disable-slash-commands", "--strict-mcp-config",
                              "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence",
                              "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                              "--json-schema", BridgePrompt.schemaJSON])
    }

    func testCodexArgumentVectorMatchesPython() throws {
        let reply = #"{"reply":"Ready","proposal":null}"#
        let runner = FakeRunner { args, _ in
            if args.contains("login") { return result(stderr: "Logged in using ChatGPT") }
            return result(lines([["type": "item.completed", "item": ["type": "agent_message", "text": reply]], ["type": "turn.completed"]]))
        }
        _ = try ProviderService(runner: runner, executableLookup: { _ in "/tool" }).generate(MessageRequest(provider: "codex", message: "Hi"))
        let main = try XCTUnwrap(runner.calls.first { $0.contains("exec") })
        XCTAssertEqual(main.count, 31)
        XCTAssertEqual(main[8], "--output-schema")
        let schemaPath = main[9]
        XCTAssertTrue(schemaPath.hasSuffix("/response-schema.json"), schemaPath)
        XCTAssertTrue(schemaPath.contains("/iris-bridge-"), schemaPath)
        var expected = ["/tool", "exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--sandbox",
                        "read-only", "--json", "--output-schema", schemaPath, "-c", "web_search=\"disabled\"",
                        "-c", "model_reasoning_effort=\"medium\""]
        for feature in ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use", "js_repl", "code_mode", "hooks"] {
            expected += ["--disable", feature]
        }
        expected.append("-")
        XCTAssertEqual(main, expected)
    }

    func testStdinWriteDoesNotEscapeTimeout() {
        let runner = ForegroundProcessRunner()
        let started = Date()
        XCTAssertThrowsError(try runner.run(["/bin/sleep", "30"], input: String(repeating: "x", count: 1_000_000),
                                            cwd: nil, timeout: 1, requestID: nil)) {
            XCTAssertEqual($0 as? BridgeError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTimeoutEscalatesToKillForSignalIgnoringChild() {
        let runner = ForegroundProcessRunner()
        let started = Date()
        XCTAssertThrowsError(try runner.run(["/bin/sh", "-c", "trap '' TERM; sleep 30"], input: nil, cwd: nil,
                                            timeout: 1, requestID: nil)) {
            XCTAssertEqual($0 as? BridgeError, .timeout)
        }
        // 1 s timeout + 3 s grace after SIGTERM + the kill itself. Anything longer means the run waited on a
        // child that was never going to leave.
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testCancelIsThePublicEntryPoint() {
        let runner = ForegroundProcessRunner()
        runner.cancel(requestID: "cancel-2")
        XCTAssertThrowsError(try runner.run(["/usr/bin/true"], input: nil, cwd: nil, timeout: 5, requestID: "cancel-2")) {
            XCTAssertEqual($0 as? BridgeError, .canceled)
        }
        runner.clearCanceled("cancel-2")
        XCTAssertEqual(try runner.run(["/usr/bin/true"], input: nil, cwd: nil, timeout: 5, requestID: "cancel-2").status, 0)
    }

    func testCanceledIDExpiresAfterTenMinutes() throws {
        var clock = Date(timeIntervalSince1970: 0)
        let runner = ForegroundProcessRunner(now: { clock })
        runner.cancel(requestID: "expire-1")
        XCTAssertThrowsError(try runner.run(["/usr/bin/true"], input: nil, cwd: nil, timeout: 5, requestID: "expire-1")) {
            XCTAssertEqual($0 as? BridgeError, .canceled)
        }
        clock = clock.addingTimeInterval(601)
        XCTAssertEqual(try runner.run(["/usr/bin/true"], input: nil, cwd: nil, timeout: 5, requestID: "expire-1").status, 0)
    }

    func testNonStringAPIKeySourceIsRejected() throws {
        // Python rejects any apiKeySource that is not None or the literal 'none', whatever its type.
        for source in [true, 1, "env"] as [Any] {
            let runner = FakeRunner { args, _ in
                if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
                if args.contains("install") || args.contains("--version") { return result("2.1.272") }
                return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": source],
                                     ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
            }
            let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" })
            XCTAssertThrowsError(try service.generate(MessageRequest(provider: "claude", message: "Hello"))) {
                XCTAssertEqual($0 as? BridgeError, .message("Claude selected API-key billing. Use your Claude account sign-in and try again."))
            }
        }
        // A JSON null counts as absent, exactly like Python's None.
        let nullRunner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": NSNull()],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        let output = try ProviderService(runner: nullRunner, executableLookup: { _ in "/tool" }).generate(MessageRequest(provider: "claude", message: "Hello"))
        XCTAssertEqual(output["model"] as? String, "m")
    }
}
