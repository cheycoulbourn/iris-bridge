import XCTest
@testable import IrisBridgeCore

/// Answers the sign-in check (`claude auth status --json`, `codex login status`) from a script, one entry per
/// check and the last entry again once the script runs out, and answers a turn with `turn`. Checks run on the
/// service's own thread, so everything it records is behind a lock.
private final class CheckRunner: ProcessRunner, @unchecked Sendable {
    typealias Answer = () throws -> ProcessResult
    private let lock = NSLock()
    private var script: [Answer]
    private var timeouts: [TimeInterval] = []
    private var turns = 0
    var turn: ProcessResult

    init(_ script: [Answer], turn: ProcessResult = CheckRunner.claudeReply) { self.script = script; self.turn = turn }

    /// The timeout each sign-in check was given, in order.
    var checkTimeouts: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return timeouts }
    var checkCount: Int { checkTimeouts.count }
    var turnCount: Int { lock.lock(); defer { lock.unlock() }; return turns }

    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        if args.contains("--version") { return ProcessResult(status: 0, stdout: "2.1.274 (Claude Code)", stderr: "") }
        if args.contains("status") {
            lock.lock()
            timeouts.append(timeout)
            let next = script.count > 1 ? script.removeFirst() : script[0]
            lock.unlock()
            return try next()
        }
        lock.lock(); turns += 1; lock.unlock()
        return turn
    }

    static let claudeReply = ProcessResult(status: 0, stdout: [
        #"{"type":"system","subtype":"init","model":"claude-opus-5-5","apiKeySource":"none"}"#,
        #"{"type":"result","subtype":"success","structured_output":{"reply":"Ready","proposal":null}}"#,
    ].joined(separator: "\n"), stderr: "")
    static let codexReply = ProcessResult(status: 0, stdout: [
        #"{"type":"item.completed","item":{"type":"agent_message","text":"{\"reply\":\"Ready\",\"proposal\":null}"}}"#,
        #"{"type":"turn.completed"}"#,
    ].joined(separator: "\n"), stderr: "")
}

private let signedIn: CheckRunner.Answer = { ProcessResult(status: 0, stdout: #"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai","email":"e@x.com"}"#, stderr: "") }
private let signedOut: CheckRunner.Answer = { ProcessResult(status: 1, stdout: #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#, stderr: "") }
private let timesOut: CheckRunner.Answer = { throw BridgeError.timeout }
private let cannotStart: CheckRunner.Answer = { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN)) }
private let unreadable: CheckRunner.Answer = { ProcessResult(status: 0, stdout: "Loading…", stderr: "") }

private func catalog(_ provider: String, _ _: String) throws -> ProviderModelCatalog {
    ProviderModelCatalog(provider: provider, models: [ProviderModel(id: "claude-custom-v1", name: "Claude", efforts: ["low", "high"])],
                         source: "test", defaultModelID: "claude-custom-v1")
}

/// A sign-in check is a CLI run like any other, and on a loaded Mac it can take many seconds. Only a check that
/// finished and said so is "signed out". One that timed out, could not start or printed nothing readable is
/// unknown: it is never cached and never stops a turn (the turn reports a real sign-out in its own words).
final class SignInCheckTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 0)

    private func service(_ runner: CheckRunner, catalogLookup: @escaping (String, String) throws -> ProviderModelCatalog = catalog) -> ProviderService {
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalogLookup, now: { [unowned self] in clock })
        service.signInRetryPause = 0
        return service
    }

    // MARK: - What counts as signed out

    func testACheckThatTimesOutIsUnknownNotSignedOut() {
        let runner = CheckRunner([timesOut])
        let status = service(runner).status("claude")
        XCTAssertFalse(status.checked)
        XCTAssertTrue(status.ready, "a sign-in nobody could check is tried, not refused")
        XCTAssertEqual(status.message, "Couldn't check Claude's sign-in just now — the Mac may be busy. Trying anyway.")
        XCTAssertNil(status.plan)
        XCTAssertEqual(runner.checkTimeouts, [ProviderService.signInTimeout, ProviderService.signInRetryTimeout], "one quick retry")
    }

    func testTheCheckIsGivenTwentySecondsNotEight() {
        let runner = CheckRunner([signedIn])
        _ = service(runner).status("claude")
        XCTAssertEqual(runner.checkTimeouts, [20])
        XCTAssertLessThanOrEqual(ProviderService.signInRetryTimeout, ProviderService.signInTimeout)
    }

    func testACheckThatCannotStartOrSaysNothingReadableIsUnknown() {
        for answer in [cannotStart, unreadable, { ProcessResult(status: 0, stdout: #"{"authMethod":"claude.ai"}"#, stderr: "") }] {
            let status = service(CheckRunner([answer])).status("claude")
            XCTAssertFalse(status.checked); XCTAssertTrue(status.ready)
        }
        for answer in [cannotStart, timesOut, { ProcessResult(status: 0, stdout: "", stderr: "") }] {
            let status = service(CheckRunner([answer])).status("codex")
            XCTAssertFalse(status.checked); XCTAssertTrue(status.ready)
            XCTAssertEqual(status.message, "Couldn't check ChatGPT's sign-in just now — the Mac may be busy. Trying anyway.")
        }
    }

    func testOnlyAFinishedCheckThatSaysSoIsSignedOut() {
        let claude = service(CheckRunner([signedOut])).status("claude")
        XCTAssertTrue(claude.checked); XCTAssertFalse(claude.ready)
        let apiKey = service(CheckRunner([{ ProcessResult(status: 0, stdout: #"{"loggedIn":true,"subscriptionType":"max","authMethod":"api_key"}"#, stderr: "") }])).status("claude")
        XCTAssertTrue(apiKey.checked); XCTAssertFalse(apiKey.ready, "API-key billing is not a subscription sign-in")
        let notLoggedIn = service(CheckRunner([{ ProcessResult(status: 1, stdout: "", stderr: "Not logged in") }])).status("codex")
        XCTAssertTrue(notLoggedIn.checked); XCTAssertFalse(notLoggedIn.ready)
        let codexKey = service(CheckRunner([{ ProcessResult(status: 0, stdout: "", stderr: "Logged in using an API key - sk-***") }])).status("codex")
        XCTAssertTrue(codexKey.checked); XCTAssertFalse(codexKey.ready)
        let chatGPT = service(CheckRunner([{ ProcessResult(status: 0, stdout: "", stderr: "Logged in using ChatGPT") }])).status("codex")
        XCTAssertTrue(chatGPT.checked); XCTAssertTrue(chatGPT.ready)
    }

    func testTheQuickRetryCanStillFindTheSignIn() {
        let runner = CheckRunner([timesOut, signedIn])
        let service = service(runner)
        let status = service.status("claude")
        XCTAssertTrue(status.checked); XCTAssertTrue(status.ready)
        XCTAssertEqual(status.plan, "Max")
        XCTAssertEqual(runner.checkCount, 2)
        _ = service.status("claude")
        XCTAssertEqual(runner.checkCount, 2, "the answer the retry found is kept like any other")
    }

    // MARK: - What is kept, and for how long

    func testAnUnknownCheckIsNeverKept() {
        let runner = CheckRunner([timesOut])
        let service = service(runner)
        _ = service.status("claude")
        XCTAssertEqual(runner.checkCount, 2)
        _ = service.status("claude")
        XCTAssertEqual(runner.checkCount, 4, "the next caller checks again")
    }

    func testASignedOutAnswerIsKeptOnlyBriefly() {
        let runner = CheckRunner([signedOut, signedIn])
        let service = service(runner)
        XCTAssertFalse(service.status("claude").ready)
        clock = clock.addingTimeInterval(9)
        XCTAssertFalse(service.status("claude").ready)
        XCTAssertEqual(runner.checkCount, 1)
        clock = clock.addingTimeInterval(2)
        XCTAssertTrue(service.status("claude").ready, "signing in on the Mac shows up within seconds")
        XCTAssertEqual(runner.checkCount, 2)
    }

    func testASignedInAnswerIsKeptForAMinute() {
        let runner = CheckRunner([signedIn])
        let service = service(runner)
        _ = service.status("claude")
        clock = clock.addingTimeInterval(59)
        _ = service.status("claude")
        XCTAssertEqual(runner.checkCount, 1)
        clock = clock.addingTimeInterval(2)
        _ = service.status("claude")
        XCTAssertEqual(runner.checkCount, 2)
    }

    // MARK: - The message path

    func testAnUnknownSignInStillTriesTheTurn() throws {
        let runner = CheckRunner([timesOut])
        let output = try service(runner).generate(MessageRequest(provider: "claude", message: "Hello"))
        XCTAssertEqual(output["reply"] as? String, "Ready")
        XCTAssertEqual(runner.turnCount, 1)
        let codex = CheckRunner([cannotStart], turn: CheckRunner.codexReply)
        XCTAssertEqual(try service(codex).generate(MessageRequest(provider: "codex", message: "Hi"))["reply"] as? String, "Ready")
        XCTAssertEqual(codex.turnCount, 1)
    }

    func testATurnTriedOnAnUnknownSignInReportsARealSignOutInClaudesWords() {
        let runner = CheckRunner([timesOut], turn: Fixture.result("claude-oauth-expired"))
        XCTAssertThrowsError(try service(runner).generate(MessageRequest(provider: "claude", message: "Hello"))) { error in
            let failure = error as? ProviderFailure
            XCTAssertEqual(failure?.cause, .signedOut)
            XCTAssertNotNil(failure?.details)
        }
        XCTAssertEqual(runner.turnCount, 1)
    }

    func testADefiniteSignOutStillRefusesBeforeAnyTurn() {
        let runner = CheckRunner([signedOut])
        XCTAssertThrowsError(try service(runner).generate(MessageRequest(provider: "claude", message: "Hello"))) { error in
            XCTAssertEqual((error as? ProviderFailure)?.cause, .signedOut)
        }
        XCTAssertEqual(runner.turnCount, 0)
    }

    func testATurnWithAnEffortChecksSignInOnce() throws {
        let runner = CheckRunner([timesOut])
        _ = try service(runner).generate(MessageRequest(provider: "claude", message: "Hi", model: "claude-custom-v1", effort: "high"))
        XCTAssertEqual(runner.checkCount, 2, "the check and its one retry; choosing the effort does not check again")
        XCTAssertEqual(runner.turnCount, 1)
    }

    // MARK: - Health and /status

    func testHealthSaysTheSignInCouldNotBeChecked() {
        let health = service(CheckRunner([timesOut])).health("claude")
        XCTAssertEqual(health, ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "2.1.274", usage: .unknown, signInChecked: false))
        XCTAssertEqual(health.json["signInChecked"] as? Bool, false)
        XCTAssertEqual(health.json["signedIn"] as? Bool, true, "older apps read `signedIn: false` as signed out")
        let checked = service(CheckRunner([signedIn])).health("claude")
        XCTAssertNil(checked.json["signInChecked"], "a finished check adds nothing to the 0.2.5 shape")
    }

    func testHealthFromAnAnswerInHandRunsNoSecondCheck() {
        let runner = CheckRunner([timesOut])
        let service = service(runner)
        let status = service.status("claude")
        _ = service.health("claude", signIn: status)
        XCTAssertEqual(runner.checkCount, 2)
    }

    func testAStatusReadThatCannotWaitAnswersAtOnceAndTheCheckFinishesBehindIt() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([{ gate.wait(); return try signedIn() }])
        let service = service(runner)
        let started = Date()
        let early = service.status("claude", wait: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(early.checked); XCTAssertTrue(early.ready)
        _ = service.status("claude", wait: 0.05)
        XCTAssertEqual(runner.checkCount, 1, "a second reader joins the check already running")
        gate.signal()
        let settled = service.status("claude")
        XCTAssertTrue(settled.checked); XCTAssertTrue(settled.ready)
        XCTAssertEqual(runner.checkCount, 1)
    }

    func testWhileARecheckRunsTheLastFinishedAnswerStands() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([signedOut, { gate.wait(); return try signedOut() }])
        let service = service(runner)
        XCTAssertFalse(service.status("claude").ready)
        clock = clock.addingTimeInterval(11)
        let during = service.status("claude", wait: 0.05)
        XCTAssertTrue(during.checked, "a signed-out Mac does not flicker to 'couldn't check' while it is asked again")
        XCTAssertFalse(during.ready)
        gate.signal()
        XCTAssertFalse(service.status("claude").ready)
    }
}
