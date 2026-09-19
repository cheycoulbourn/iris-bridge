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
private func catalog(_ provider: String, _ _: String) throws -> ProviderModelCatalog {
    if provider == "codex" {
        return ProviderModelCatalog(provider: provider, models: [ProviderModel(id: "gpt-custom-v1", name: "Codex", efforts: ["low", "medium", "high"], defaultEffort: "medium")], source: "test", defaultModelID: "gpt-custom-v1")
    }
    return ProviderModelCatalog(provider: provider, models: [ProviderModel(id: "claude-custom-v1", name: "Claude", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium")], source: "test", defaultModelID: "claude-custom-v1")
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
    func testModelCatalogCacheIsExplicitlyLabeled() {
        let runner = FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalog)
        XCTAssertEqual(service.models("codex").source, "test")
        let cached = service.models("codex")
        XCTAssertEqual(cached.source, "cached-test")
        XCTAssertEqual(cached.notice, "Cached less than one minute ago.")
    }
    func testCachedUnavailableCatalogPreservesAutomaticGuidanceAndNilDefault() {
        let runner = FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: { provider, _ in
            ProviderModelCatalog(provider: provider, models: [], source: "unavailable", notice: "Keep Automatic selected and try again.")
        })
        _ = service.models("codex")
        let cached = service.models("codex")
        XCTAssertEqual(cached.source, "cached-unavailable")
        XCTAssertNil(cached.defaultModelID)
        XCTAssertEqual(cached.notice, "Keep Automatic selected and try again. Cached less than one minute ago.")
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

    // MARK: - Verbatim contract

    func testSystemPromptCarriesTheVerbatimImportContract() {
        XCTAssertGreaterThan(BridgePrompt.system.count, 1500)
        XCTAssertTrue(BridgePrompt.system.hasPrefix("You are Iris, Iris's content planning as"))
        XCTAssertTrue(BridgePrompt.system.hasSuffix("ed; only the creator can decide in Iris."))
        XCTAssertTrue(BridgePrompt.system.contains("copy the original writing exactly"))
        XCTAssertTrue(BridgePrompt.system.contains("never paraphrase, shorten or rewrite it"))
        XCTAssertTrue(BridgePrompt.system.contains("ask specific clarification questions"))
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
        XCTAssertEqual(main, ["/tool", "-p", "--safe-mode", "--tools", "",
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
        XCTAssertEqual(main.count, 29)
        XCTAssertEqual(main[8], "--output-schema")
        let schemaPath = main[9]
        XCTAssertTrue(schemaPath.hasSuffix("/response-schema.json"), schemaPath)
        XCTAssertTrue(schemaPath.contains("/iris-bridge-"), schemaPath)
        var expected = ["/tool", "exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--sandbox",
                        "read-only", "--json", "--output-schema", schemaPath, "-c", "web_search=\"disabled\""]
        for feature in ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use", "js_repl", "code_mode", "hooks"] {
            expected += ["--disable", feature]
        }
        expected.append("-")
        XCTAssertEqual(main, expected)
    }

    func testSelectedModelIsForwardedToClaude() throws {
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": "none"],
                                 ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]]))
        }
        _ = try ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalog).generate(MessageRequest(provider: "claude", message: "Hello", model: "claude-custom-v1"))
        let main = try XCTUnwrap(runner.calls.first { $0.contains("--json-schema") })
        let index = try XCTUnwrap(main.firstIndex(of: "--model"))
        XCTAssertEqual(main[index + 1], "claude-custom-v1")
    }

    func testSelectedModelIsForwardedToCodex() throws {
        let reply = #"{"reply":"Ready","proposal":null}"#
        let runner = FakeRunner { args, _ in
            if args.contains("login") { return result(stderr: "Logged in using ChatGPT") }
            return result(lines([["type": "item.completed", "item": ["type": "agent_message", "text": reply]], ["type": "turn.completed"]]))
        }
        _ = try ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalog).generate(MessageRequest(provider: "codex", message: "Hi", model: "gpt-custom-v1"))
        let main = try XCTUnwrap(runner.calls.first { $0.contains("exec") })
        let index = try XCTUnwrap(main.firstIndex(of: "--model"))
        XCTAssertEqual(main[index + 1], "gpt-custom-v1")
    }

    func testNilModelLeavesProviderDefaultsUnselected() throws {
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            if args.contains("login") { return result(stderr: "Logged in using ChatGPT") }
            if args.contains("--json-schema") { return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": "none"], ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]])) }
            return result(lines([["type": "item.completed", "item": ["type": "agent_message", "text": #"{"reply":"Ready","proposal":null}"#]], ["type": "turn.completed"]]))
        }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" })
        _ = try service.generate(MessageRequest(provider: "claude", message: "Hello"))
        _ = try service.generate(MessageRequest(provider: "codex", message: "Hi"))
        XCTAssertFalse(runner.calls.contains { $0.contains("--model") })
    }

    func testSelectedEffortIsForwardedToEachProvider() throws {
        let runner = FakeRunner { args, _ in
            if args.contains("auth") { return result(#"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#) }
            if args.contains("install") || args.contains("--version") { return result("2.1.272") }
            if args.contains("login") { return result(stderr: "Logged in using ChatGPT") }
            if args.contains("--json-schema") { return result(lines([["type": "system", "subtype": "init", "model": "m", "apiKeySource": "none"], ["type": "result", "subtype": "success", "structured_output": ["reply": "Ready", "proposal": NSNull()]]])) }
            return result(lines([["type": "item.completed", "item": ["type": "agent_message", "text": #"{"reply":"Ready","proposal":null}"#]], ["type": "turn.completed"]]))
        }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalog)
        _ = try service.generate(MessageRequest(provider: "claude", message: "Hi", model: "claude-custom-v1", effort: "xhigh"))
        _ = try service.generate(MessageRequest(provider: "codex", message: "Hi", model: "gpt-custom-v1", effort: "high"))
        let claude = try XCTUnwrap(runner.calls.first { $0.contains("--json-schema") })
        XCTAssertEqual(claude[try XCTUnwrap(claude.firstIndex(of: "--effort")) + 1], "xhigh")
        let codex = try XCTUnwrap(runner.calls.first { $0.contains("exec") })
        XCTAssertTrue(codex.contains("model_reasoning_effort=\"high\""))
    }

    func testUnsupportedEffortAndUnavailableCatalogAreRejectedBeforeGeneration() {
        let runner = FakeRunner { _, _ in result(stderr: "Logged in using ChatGPT") }
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalog)
        XCTAssertThrowsError(try service.generate(MessageRequest(provider: "codex", message: "Hi", model: "gpt-custom-v1", effort: "xhigh"))) { error in
            XCTAssertEqual(error as? BridgeError, .message("That effort is not available for the selected model."))
        }
        let unavailable = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: { _, _ in throw BridgeError.timeout })
        XCTAssertThrowsError(try unavailable.generate(MessageRequest(provider: "codex", message: "Hi", effort: "high"))) { error in
            XCTAssertEqual(error as? BridgeError, .message("Model choices are unavailable. Keep Automatic selected and try again."))
        }
    }

    func testCatalogDiscoveryParsesChunkedCodexAndClaudeControlStreams() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("iris-catalog-stub-\(UUID().uuidString).sh")
        let contents = #"""
        #!/bin/sh
        IFS= read -r first || exit 1
        case "$*" in
          *app-server*)
            printf '%s' '{"id":"initialize","result":'
            printf '%s\n' '{}}'
            IFS= read -r second || exit 1
            printf '%s' '{"id":"models-0","result":{"data":[{"model":"codex-live","displayName":"Codex Live","hidden":false,"isDefault":true,"defaultReasoningEffort":"ultra","supportedReasoningEfforts":[{"reasoningEffort":"none"},{"reasoningEffort":"ultra"}]}]'
            printf '%s\n' '}}'
            ;;
          *)
            printf '%s' '{"type":"control_response","response":{"request_id":"iris-'
            printf '%s\n' 'models","subtype":"success","response":{"models":[{"value":"claude-live","displayName":"Claude Live","supportsEffort":true,"supportedEffortLevels":["low","max"]}]}}}'
            ;;
        esac
        """#
        try (contents.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let codex = try ProviderService.discoverCatalog(provider: "codex", binary: script.path)
        XCTAssertEqual(codex.models, [ProviderModel(id: "codex-live", name: "Codex Live", efforts: ["none", "ultra"], defaultEffort: "ultra")])
        let claude = try ProviderService.discoverCatalog(provider: "claude", binary: script.path)
        XCTAssertEqual(claude.models, [ProviderModel(id: "claude-live", name: "Claude Live", efforts: ["low", "max"])])
    }

    func testLiveCatalogDiscoveryUsesShippingParserWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["IRIS_BRIDGE_LIVE_CATALOG"] == "1" else {
            throw XCTSkip("Set IRIS_BRIDGE_LIVE_CATALOG=1 for local, read-only installed-CLI discovery.")
        }
        for provider in ["codex", "claude"] {
            guard let binary = ProviderService.findExecutable(provider) else {
                throw XCTSkip("\(provider) is not installed on this Mac.")
            }
            let catalog = try ProviderService.discoverCatalog(provider: provider, binary: binary)
            XCTAssertEqual(catalog.provider, provider)
            XCTAssertFalse(catalog.models.isEmpty)
            XCTAssertEqual(Set(catalog.models.map(\.id)).count, catalog.models.count)
        }
    }

    func testCodexCatalogUsesOnlyServerAdvertisedModelCapabilities() {
        let reply: [String: Any] = ["data": [["model": "gpt-real", "displayName": "Codex Real", "hidden": false, "isDefault": true,
                                                   "defaultReasoningEffort": "high", "supportedReasoningEfforts": [["reasoningEffort": "none"], ["reasoningEffort": "minimal"], ["reasoningEffort": "ultra"]]],
                                                 ["model": "gpt-real", "displayName": "Duplicate", "hidden": false, "isDefault": false,
                                                   "supportedReasoningEfforts": []],
                                                 ["model": "gpt-hidden", "displayName": "Hidden", "hidden": true, "isDefault": false,
                                                   "defaultReasoningEffort": "medium", "supportedReasoningEfforts": [["reasoningEffort": "medium"]]]]]
        let result = ProviderService.codexCatalog(from: reply)
        XCTAssertEqual(result?.source, "live-codex-app-server")
        XCTAssertEqual(result?.defaultModelID, "gpt-real")
        XCTAssertEqual(result?.models, [ProviderModel(id: "gpt-real", name: "Codex Real", efforts: ["none", "minimal", "ultra"], defaultEffort: "high")])
    }

    func testClaudeCatalogUsesInitializeCapabilitiesWithoutAliasFallback() {
        let reply: [String: Any] = ["models": [["value": "default", "displayName": "Default", "supportsEffort": true,
                                                   "supportedEffortLevels": ["low", "ultra"]],
                                                 ["value": "claude-haiku", "displayName": "Haiku", "supportsEffort": false],
                                                 ["value": "default", "displayName": "Duplicate", "supportsEffort": true,
                                                   "supportedEffortLevels": ["max"]]]]
        let result = ProviderService.claudeCatalog(from: reply)
        XCTAssertEqual(result?.source, "live-claude-sdk-initialize")
        XCTAssertEqual(result?.defaultModelID, "default")
        XCTAssertEqual(result?.models, [ProviderModel(id: "default", name: "Default", efforts: ["low", "ultra"]),
                                       ProviderModel(id: "claude-haiku", name: "Haiku", efforts: [])])
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
