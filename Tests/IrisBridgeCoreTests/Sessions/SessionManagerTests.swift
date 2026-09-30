import XCTest
@testable import IrisBridgeCore

/// A provider whose sessions the test drives by hand.
private final class FakeAdapter: ProviderAdapter {
    final class Session: ProviderSession {
        let sessionId: String?
        let model: String?
        let effort: String?
        var isLive = true
        var sent: [TurnRequest] = []
        var cancels = 0, stops = 0
        let emit: (ProviderEvent) -> Void
        init(id: String?, model: String?, effort: String?, emit: @escaping (ProviderEvent) -> Void) {
            sessionId = id; self.model = model; self.effort = effort; self.emit = emit
        }
        func send(_ turn: TurnRequest) throws { sent.append(turn) }
        func cancel() { cancels += 1 }
        func stop() { stops += 1; isLive = false }
    }

    let provider: Provider
    var sessions: [Session] = []
    var resumes: [String?] = []
    var failure: ProviderFailure?
    init(_ provider: Provider) { self.provider = provider }

    func session(threadId: String, resume sessionId: String?, model: String?, effort: String?, events: @escaping (ProviderEvent) -> Void) throws -> ProviderSession {
        if let failure { throw failure }
        resumes.append(sessionId)
        let session = Session(id: provider == .claude ? (sessionId ?? "claude-\(sessions.count + 1)") : sessionId, model: model, effort: effort, emit: events)
        sessions.append(session)
        return session
    }

    func health() -> ProviderHealth { ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "", usage: .unknown) }
}

final class SessionManagerTests: XCTestCase {
    private var folder: URL!
    private var claude: FakeAdapter!
    private var codex: FakeAdapter!
    private var outbox: FakeOutbox!
    private var manager: SessionManager!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private let a = "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77"

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        claude = FakeAdapter(.claude); codex = FakeAdapter(.codex); outbox = FakeOutbox()
        manager = makeManager()
    }

    private func makeManager(limits: SessionManager.Limits = .standard) -> SessionManager {
        let manager = SessionManager(adapters: [claude, codex], events: EventLog(folder: folder.appendingPathComponent("events")),
                                     index: SessionIndex(file: folder.appendingPathComponent("sessions/index.json")), log: nil,
                                     limits: limits, now: { [unowned self] in self.clock })
        manager.outbox = outbox
        return manager
    }

    private func send(_ thread: String? = nil, turn: String = "t1", provider: Provider = .claude, text: String = "Plan my week",
                      model: String? = nil, effort: String? = nil, mentions: [String]? = nil, command: AppMessage.Command? = nil,
                      catchUp: [AppMessage.CatchUp]? = nil) {
        manager.send(AppMessage.ThreadSend(threadId: thread ?? a, turnId: turn, provider: provider, model: model, effort: effort, text: text,
                                           command: command, mentions: mentions, attachments: nil, catchUp: catchUp))
        _ = manager.turnContext(threadId: thread ?? a)   // waits for the send to be handled
    }

    private func sent(_ type: String) -> [JSONValue] { outbox.broadcasts.filter { $0["type"]?.stringValue == type } }

    func testAMessageStartsASessionSendsTheTurnAndLogsTurnStarted() throws {
        send(mentions: ["claude_ai_Gmail"], command: .init(kind: "iris", name: "plan-week", connectors: ["claude_ai_Google_Calendar"]))
        let session = try XCTUnwrap(claude.sessions.first)
        XCTAssertEqual(session.sent.map(\.text), ["Plan my week"])
        XCTAssertEqual(sent("turn.started").first?["sessionId"], "claude-1")
        XCTAssertEqual(sent("turn.started").first?["seq"]?.intValue, 1)
        XCTAssertEqual(SessionIndex(file: folder.appendingPathComponent("sessions/index.json")).sessionId(threadId: a, provider: .claude), "claude-1")
        let context = try XCTUnwrap(manager.turnContext(threadId: a))
        XCTAssertEqual(context.mentions, ["claude_ai_Gmail"])
        XCTAssertEqual(context.commandConnectors, ["claude_ai_Google_Calendar"])
        XCTAssertEqual(context.turnId, "t1")
    }

    func testTurnEventsAreLoggedBroadcastAndTheTurnEnds() throws {
        send()
        let session = claude.sessions[0]
        session.emit(.turn(turnId: "t1", .textDelta("Hello")))
        session.emit(.turn(turnId: "t1", .completed(TurnUsage(inputTokens: 1))))
        session.emit(.turn(turnId: "t1", .textDelta("late")))
        XCTAssertNil(manager.turnContext(threadId: a))
        XCTAssertEqual(outbox.broadcasts.map { $0["type"] }, ["turn.started", "text.delta", "turn.completed"])
        XCTAssertEqual(manager.replay(threadId: a, after: 1).map { $0["type"] }, ["text.delta", "turn.completed"])
    }

    func testPostReferencesAreIDOnlyReplayableAndDeduplicatedPerTurn() {
        let post = "C0000000-0000-4000-8000-000000000001"
        let profile = SnapshotFixture.profile
        send(provider: .codex)
        manager.referencePost(threadId: a, turnId: "t1", postID: post.lowercased(), profileID: profile.lowercased())
        manager.referencePost(threadId: a, turnId: "t1", postID: post, profileID: profile)
        manager.referencePost(threadId: a, turnId: "wrong", postID: UUID().uuidString, profileID: profile)
        manager.referencePost(threadId: a, turnId: "t1", postID: "bad", profileID: profile)
        manager.referencePost(threadId: a, turnId: "t1", postID: post, profileID: "bad")
        _ = manager.turnContext(threadId: a)
        XCTAssertEqual(sent("post.referenced"), [["type": "post.referenced", "threadId": .string(a), "turnId": "t1", "seq": 2,
                                                   "postID": .string(post), "profileID": .string(profile)]])
        XCTAssertEqual(manager.replay(threadId: a, after: 1), sent("post.referenced"))
        codex.sessions[0].emit(.turn(turnId: "t1", .completed(TurnUsage())))
        manager.referencePost(threadId: a, turnId: "t1", postID: UUID().uuidString, profileID: profile)
        _ = manager.turnContext(threadId: a)
        XCTAssertEqual(sent("post.referenced").count, 1, "a late read must not add cards after completion")
        send(turn: "t2", provider: .claude)
        manager.referencePost(threadId: a, turnId: "t1", postID: UUID().uuidString, profileID: profile)
        manager.referencePost(threadId: a, turnId: "t2", postID: post, profileID: profile)
        _ = manager.turnContext(threadId: a)
        XCTAssertEqual(sent("post.referenced").count, 2, "the new turn can reference the same post, but an old turn cannot")
    }

    func testTheNextMessageReusesTheLiveSessionAndAModelChangeResumesIt() throws {
        send()
        claude.sessions[0].emit(.turn(turnId: "t1", .completed(TurnUsage())))
        send(turn: "t2")
        XCTAssertEqual(claude.sessions.count, 1)
        XCTAssertEqual(claude.sessions[0].sent.count, 2)
        claude.sessions[0].emit(.turn(turnId: "t2", .completed(TurnUsage())))
        send(turn: "t3", model: "sonnet")
        XCTAssertEqual(claude.sessions.count, 2)
        XCTAssertEqual(claude.resumes, [nil, "claude-1"])
        XCTAssertEqual(claude.sessions[0].stops, 1)
    }

    /// spec-adjacent (`effort` capability): a turn answered on Automatic, then a later send asking for a
    /// specific effort restarts the process with `--resume` once that turn is done, keeping history.
    func testAnEffortChangeResumesTheSessionAfterTheRunningTurnEnds() throws {
        send(effort: nil)
        claude.sessions[0].emit(.turn(turnId: "t1", .completed(TurnUsage())))
        send(turn: "t2", effort: "high")
        XCTAssertEqual(claude.sessions.count, 2)
        XCTAssertEqual(claude.resumes, [nil, "claude-1"])
        XCTAssertEqual(claude.sessions[0].stops, 1)
        XCTAssertEqual(claude.sessions[1].effort, "high")
        XCTAssertEqual(claude.sessions[1].sent.map(\.text), ["Plan my week"])
    }

    func testTheSameEffortOnTheNextMessageDoesNotRestart() throws {
        send(effort: "xhigh")
        claude.sessions[0].emit(.turn(turnId: "t1", .completed(TurnUsage())))
        send(turn: "t2", effort: "xhigh")
        XCTAssertEqual(claude.sessions.count, 1)
        XCTAssertEqual(claude.sessions[0].stops, 0)
        XCTAssertEqual(claude.sessions[0].sent.count, 2)
    }

    /// An omitted effort on a later send makes no claim either way, exactly like an omitted model: the
    /// session already running (started with an effort) keeps answering unchanged.
    func testAnOmittedEffortOnTheNextMessageKeepsTheRunningSession() throws {
        send(effort: "medium")
        claude.sessions[0].emit(.turn(turnId: "t1", .completed(TurnUsage())))
        send(turn: "t2", effort: nil)
        XCTAssertEqual(claude.sessions.count, 1)
        XCTAssertEqual(claude.sessions[0].stops, 0)
    }

    func testOneTurnPerThreadAndThreeAcrossTheMac() {
        send()
        send(turn: "t2")
        XCTAssertEqual(sent("turn.failed").last?["message"], "This chat is still answering. Stop it or wait for it to finish.")
        XCTAssertEqual(sent("turn.failed").last?["cause"], "busy")
        for index in 2...3 { send(UUID().uuidString, turn: "t\(index)") }
        send(UUID().uuidString, turn: "t9")
        XCTAssertEqual(sent("turn.failed").last?["message"], "Three chats are already answering on your Mac. Try again when one finishes.")
        XCTAssertEqual(claude.sessions.count, 3)
    }

    func testABadMessageAndASignedOutProviderFailWithoutStartingAnything() {
        send(text: " ")
        XCTAssertEqual(sent("turn.failed").last?["cause"], "badRequest")
        XCTAssertEqual(sent("turn.failed").last?["message"], "Enter a message.")
        manager.readiness = { provider in ProviderFailure(cause: .signedOut, provider: provider.rawValue) }
        send(turn: "t2")
        XCTAssertEqual(sent("turn.failed").last?["message"], "Claude is signed out on your Mac. On the Mac, open Terminal and run `claude auth login`.")
        XCTAssertTrue(claude.sessions.isEmpty)
        XCTAssertTrue(sent("turn.started").isEmpty)
    }

    func testCancelReachesTheSessionAndEndsWaitingApprovals() throws {
        final class Turns: TurnContextProvider { func turnContext(threadId: String) -> TurnContext? { nil } }
        let broker = ApprovalBroker(turns: Turns(), log: nil)
        manager.approvals = broker
        send()
        manager.cancel(AppMessage.TurnCancel(threadId: a, turnId: "other"))
        manager.cancel(AppMessage.TurnCancel(threadId: a, turnId: "t1"))
        _ = manager.turnContext(threadId: a)
        XCTAssertEqual(claude.sessions[0].cancels, 1)
    }

    func testOpeningAThreadWarmsItsSessionOnce() {
        manager.open(AppMessage.ThreadOpen(threadId: a, provider: .claude, model: "haiku"))
        manager.open(AppMessage.ThreadOpen(threadId: a, provider: .claude, model: "haiku"))
        _ = manager.turnContext(threadId: a)
        XCTAssertEqual(claude.sessions.count, 1)
        send(model: "haiku")
        XCTAssertEqual(claude.sessions.count, 1, "the warm session answers the first message")
        XCTAssertEqual(claude.sessions[0].sent.count, 1)
    }

    func testCodexLearnsItsSessionIdFromTheRunAndResumesByItAfterARestart() {
        send(provider: .codex)
        codex.sessions[0].emit(.session(id: "0199a213-81c0-7800-8aa1-bbab2a035a53"))
        codex.sessions[0].emit(.turn(turnId: "t1", .completed(TurnUsage())))
        _ = manager.turnContext(threadId: a)
        manager = makeManager()
        send(turn: "t2", provider: .codex)
        XCTAssertEqual(codex.resumes.last, "0199a213-81c0-7800-8aa1-bbab2a035a53")
    }

    func testAResumeThatFailsIsForgottenSoTheThreadIsNotStuck() {
        SessionIndex(file: folder.appendingPathComponent("sessions/index.json")).set("gone-session", threadId: a, provider: .claude)
        manager = makeManager()
        send()
        claude.sessions[0].emit(.turn(turnId: "t1", .failed(ProviderFailure(cause: .internal, provider: "claude", details: "No conversation found with session ID: gone-session"))))
        _ = manager.turnContext(threadId: a)
        XCTAssertNil(SessionIndex(file: folder.appendingPathComponent("sessions/index.json")).sessionId(threadId: a, provider: .claude))
        send(turn: "t2")
        XCTAssertEqual(claude.resumes, ["gone-session", nil])
    }

    func testIdleSessionsStopAndTheLiveOnesAreCapped() {
        manager = makeManager(limits: SessionManager.Limits(activeTurns: 3, idle: 60, liveSessions: 2))
        let threads = (0..<3).map { _ in UUID().uuidString }
        for (index, thread) in threads.enumerated() {
            manager.open(AppMessage.ThreadOpen(threadId: thread, provider: .claude, model: nil))
            _ = manager.turnContext(threadId: thread)
            clock = clock.addingTimeInterval(Double(index + 1))
        }
        XCTAssertEqual(claude.sessions.filter(\.isLive).count, 2, "the oldest idle session made room")
        XCTAssertEqual(claude.sessions[0].stops, 1)
        clock = clock.addingTimeInterval(61)
        manager.stopIdleSessions()
        _ = manager.turnContext(threadId: threads[0])
        XCTAssertEqual(claude.sessions.filter(\.isLive).count, 0, "sessions idle past the limit stop")
    }

    func testCatchUpAndClaudeCommandsShapeTheTurnText() {
        send(text: "and make it three", command: .init(kind: "claude", name: "brainstorm", connectors: nil),
             catchUp: [.init(role: "user", text: "Ideas for Friday?"), .init(role: "assistant", text: "Here are five.")])
        XCTAssertEqual(claude.sessions[0].sent.first?.text, """
        /brainstorm and make it three

        While you were away, the creator continued this conversation on their phone:
        Creator: Ideas for Friday?
        Iris: Here are five.
        """)
    }
}
