import XCTest
@testable import IrisBridgeCore

/// The whole v3 helper over a real TLS WebSocket, the way the app will use it, with Claude replaced by a
/// recorded transcript and no CLI run: hello, a turn streamed to the end, replay after a reconnect, a snapshot
/// the read tools answer from, and a change the app answers.
final class BridgeRuntimeTests: XCTestCase {
    private let thread = "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77"
    private var root: URL!
    private var token = ""
    private var fingerprint = ""
    private var server: BridgeServer!
    private var router: Router!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = BridgePaths(root: root, logs: root.appendingPathComponent("logs"))
        try paths.prepare()
        let identity = try CertificateManager.load(paths: paths)
        fingerprint = identity.fingerprint
        let devices = DeviceStore(file: paths.devices)
        token = try devices.issue(name: "Test phone", platform: "iphone").token
        /// Health checks sign-in with `claude auth status` and `codex login status`; both answer "signed in".
        final class SignedIn: ProcessRunner {
            func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
                if args.contains("auth") { return ProcessResult(status: 0, stdout: #"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#, stderr: "") }
                return ProcessResult(status: 0, stdout: "", stderr: "Logged in using ChatGPT")
            }
        }
        let runtime = BridgeRuntime(paths: paths, port: 0, fingerprint: identity.fingerprint, hostName: "Test Mac", adminToken: String(repeating: "a", count: 40),
                                    devices: devices, pairing: PairingCodeStore(), inbox: InboxStore(file: paths.inbox), context: ContextStore(file: paths.context),
                                    log: nil, helperBinary: "/usr/local/bin/iris-bridge", generator: IdleGenerator(),
                                    providers: ProviderService(runner: SignedIn(), executableLookup: { "/usr/local/bin/\($0)" }),
                                    executables: { "/usr/local/bin/\($0)" }, launcher: ScriptedLauncher("claude-session-turns"),
                                    claudeSettings: root.appendingPathComponent("no-settings.json"))
        router = runtime.router
        server = try BridgeServer(port: 0, identity: identity, router: runtime.router, serviceName: "Test Mac", advertise: false, log: nil, streams: runtime.hub)
        try server.start()
        session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
    }

    override func tearDown() { server.stop(); try? FileManager.default.removeItem(at: root) }

    private func connect(cursors: String = "{}") -> (URLSessionWebSocketTask, JSONValue?) {
        let task = session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(server.actualPort!)/v3/stream")!)
        task.resume()
        sendText(task, #"{"type":"hello","deviceToken":"\#(token)","appVersion":"test","protocol":3,"cursors":\#(cursors)}"#)
        return (task, receiveMessages(task, count: 1).first)
    }

    /// Reads until a message of `type` arrives; returns everything read.
    private func read(_ task: URLSessionWebSocketTask, until type: String) -> [JSONValue] {
        var all: [JSONValue] = []
        for _ in 0..<60 {
            let batch = receiveMessages(task, count: 1, timeout: 5)
            all += batch
            if batch.isEmpty || batch.contains(where: { $0["type"]?.stringValue == type }) { break }
        }
        return all
    }

    private func adminTool(_ name: String, _ arguments: String = "{}") -> JSONValue {
        let request = HTTPRequest(method: "POST", path: "/admin/v3/tool", headers: ["authorization": "Bearer " + String(repeating: "a", count: 40)],
                                  body: Data(#"{"name":"\#(name)","arguments":\#(arguments),"agent":"claude"}"#.utf8))
        return (try? JSONValue.decode(router.handle(request, context: RequestContext(sourceAddress: "127.0.0.1", isLoopback: true)).body)) ?? .null
    }

    func testHelloStreamsATurnAndAReconnectReplaysFromItsCursor() {
        let (task, hello) = connect()
        XCTAssertEqual(hello?["type"], "hello.ok")
        XCTAssertTrue(hello?["capabilities"]?.arrayValue?.contains("v3") ?? false)
        XCTAssertNotNil(hello?["health"]?["claude"])
        sendText(task, #"{"type":"thread.send","threadId":"\#(thread)","turnId":"t1","provider":"claude","text":"Good morning"}"#)
        let turn = read(task, until: "turn.completed").filter { $0["threadId"]?.stringValue == thread }
        XCTAssertEqual(turn.compactMap { $0["type"]?.stringValue }, ["turn.started", "thinking", "text.delta", "text.delta", "turn.completed"])
        XCTAssertEqual(turn.filter { $0["type"] == "text.delta" }.compactMap { $0["text"]?.stringValue }.joined(), "Good morning.")
        XCTAssertEqual(turn.first { $0["type"] == "turn.completed" }?["seq"]?.intValue, 5)
        task.cancel(with: .normalClosure, reason: nil)

        let (again, _) = connect(cursors: #"{"\#(thread)":2}"#)
        let replayed = receiveMessages(again, count: 3)
        XCTAssertEqual(replayed.compactMap { $0["seq"]?.intValue }, [3, 4, 5])
        again.cancel(with: .normalClosure, reason: nil)
    }

    func testAPushedSnapshotAnswersTheReadToolsAndAChangeReachesTheApp() throws {
        let (task, _) = connect()
        let snapshot = String(decoding: SnapshotFixture.json.encoded(), as: UTF8.self)
        sendText(task, #"{"type":"snapshot.push","profileId":"\#(SnapshotFixture.profile)","revision":"rev-1","snapshot":\#(snapshot)}"#)
        var summary = JSONValue.null
        for _ in 0..<50 where summary["isError"] != false { summary = adminTool("iris_workspace_summary"); Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(summary["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("Robin Vale") ?? false)

        var change = JSONValue.null
        let done = expectation(description: "tool answered")
        DispatchQueue.global().async {
            change = self.adminTool("iris_create_task", #"{"title":"Film the intro"}"#)
            done.fulfill()
        }
        let request = read(task, until: "action.request").first { $0["type"] == "action.request" }
        XCTAssertEqual(request?["action"]?["actions"]?.arrayValue?.first?["name"], "iris_create_task")
        XCTAssertEqual(request?["action"]?["origin"]?["agent"], "claude")
        let actionId = try XCTUnwrap(request?["actionId"]?.stringValue)
        sendText(task, #"{"type":"action.result","actionId":"\#(actionId)","result":{"status":"ok","recordIDs":["F0000000-0000-4000-8000-000000000009"],"activityID":"act:x"}}"#)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(change["isError"], false)
        XCTAssertTrue(change["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("F0000000-0000-4000-8000-000000000009") ?? false)
        task.cancel(with: .normalClosure, reason: nil)
    }
}
