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
    private var providers: [String] = []
    private var turns = 0
    private var versionScript: [Answer] = [{ ProcessResult(status: 0, stdout: "2.1.274 (Claude Code)", stderr: "") }]
    private var versions = 0
    var turn: ProcessResult

    init(_ script: [Answer], turn: ProcessResult = CheckRunner.claudeReply) { self.script = script; self.turn = turn }

    /// What `--version` answers, one entry per read and the last entry again once the script runs out.
    func answerVersions(_ script: [Answer]) { lock.lock(); versionScript = script; lock.unlock() }
    var versionReads: Int { lock.lock(); defer { lock.unlock() }; return versions }

    /// The timeout each sign-in check was given, in order.
    var checkTimeouts: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return timeouts }
    var checkCount: Int { checkTimeouts.count }
    /// The provider each sign-in check asked about, in order.
    var checkedProviders: [String] { lock.lock(); defer { lock.unlock() }; return providers }
    var turnCount: Int { lock.lock(); defer { lock.unlock() }; return turns }

    func run(_ args: [String], input: String?, cwd: URL?, timeout: TimeInterval, requestID: String?) throws -> ProcessResult {
        if args.contains("--version") {
            lock.lock()
            versions += 1
            let next = versionScript.count > 1 ? versionScript.removeFirst() : versionScript[0]
            lock.unlock()
            return try next()
        }
        if args.contains("status") {
            lock.lock()
            timeouts.append(timeout)
            providers.append(args.contains("auth") ? "claude" : "codex")
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
private let chatGPT: CheckRunner.Answer = { ProcessResult(status: 0, stdout: "", stderr: "Logged in using ChatGPT") }
/// `codex login --with-api-key` saves the key in Codex's own auth file, so a clean environment still bills it.
private let codexAPIKey: CheckRunner.Answer = { ProcessResult(status: 0, stdout: "", stderr: "Logged in using an API key - sk-proj-***") }
private let claudeAPIKey: CheckRunner.Answer = { ProcessResult(status: 0, stdout: #"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}"#, stderr: "") }

private func catalog(_ provider: String, _ _: String) throws -> ProviderModelCatalog {
    ProviderModelCatalog(provider: provider, models: [ProviderModel(id: "claude-custom-v1", name: "Claude", efforts: ["low", "high"])],
                         source: "test", defaultModelID: "claude-custom-v1")
}

/// A sign-in check is a CLI run like any other, and on a loaded Mac it can take many seconds. Only a check that
/// finished and said so is "signed out". One that timed out, could not start or printed nothing readable is
/// unknown: it is never cached, and a turn is tried on it only when this Mac confirmed a subscription sign-in
/// earlier (the turn then reports a real sign-out in its own words). Without that, nothing has ruled out an API
/// key, so no turn runs, and the refusal does not call the Mac signed out. Either way apps are not shown it as
/// signed out.
final class SignInCheckTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 0)

    private func service(_ runner: CheckRunner, catalogLookup: @escaping (String, String) throws -> ProviderModelCatalog = catalog) -> ProviderService {
        let service = ProviderService(runner: runner, executableLookup: { _ in "/tool" }, catalogLookup: catalogLookup, now: { [unowned self] in clock })
        service.signInRetryPause = 0
        return service
    }

    /// A service on a Mac that confirmed a subscription sign-in a minute ago, with that answer no longer kept.
    /// The runner's first answer must be that sign-in.
    private func confirmedEarlier(_ runner: CheckRunner, _ provider: String = "claude") -> ProviderService {
        let service = service(runner)
        let first = service.status(provider)
        XCTAssertTrue(first.checked && first.ready)
        clock = clock.addingTimeInterval(ProviderService.signedInLifetime + 1)
        return service
    }

    // MARK: - What counts as signed out

    func testACheckThatTimesOutIsUnknownNotSignedOut() {
        let runner = CheckRunner([timesOut])
        let status = service(runner).status("claude")
        XCTAssertFalse(status.checked)
        XCTAssertFalse(status.ready, "nothing on this Mac has confirmed a subscription sign-in yet")
        XCTAssertEqual(status.message, "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment.")
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
            XCTAssertFalse(status.checked); XCTAssertFalse(status.ready)
        }
        for answer in [cannotStart, timesOut, { ProcessResult(status: 0, stdout: "", stderr: "") }] {
            let status = service(CheckRunner([answer])).status("codex")
            XCTAssertFalse(status.checked); XCTAssertFalse(status.ready)
            XCTAssertEqual(status.message, "Couldn't check ChatGPT's sign-in just now — the Mac may be busy. Try again in a moment.")
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

    func testAnUnknownSignInStillTriesTheTurnWhenTheMacConfirmedASubscriptionEarlier() throws {
        let runner = CheckRunner([signedIn, timesOut])
        let output = try confirmedEarlier(runner).generate(MessageRequest(provider: "claude", message: "Hello"))
        XCTAssertEqual(output["reply"] as? String, "Ready")
        XCTAssertEqual(output["auth"] as? String, "subscription")
        XCTAssertEqual(runner.turnCount, 1)
        XCTAssertEqual(runner.checkCount, 3, "the turn's own check and its retry did not finish")
        let codex = CheckRunner([chatGPT, cannotStart], turn: CheckRunner.codexReply)
        XCTAssertEqual(try confirmedEarlier(codex, "codex").generate(MessageRequest(provider: "codex", message: "Hi"))["reply"] as? String, "Ready")
        XCTAssertEqual(codex.turnCount, 1)
    }

    func testATurnTriedOnAnUnknownSignInReportsARealSignOutInClaudesWords() {
        let runner = CheckRunner([signedIn, timesOut], turn: Fixture.result("claude-oauth-expired"))
        XCTAssertThrowsError(try confirmedEarlier(runner).generate(MessageRequest(provider: "claude", message: "Hello"))) { error in
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
        let runner = CheckRunner([signedIn, timesOut])
        _ = try confirmedEarlier(runner).generate(MessageRequest(provider: "claude", message: "Hi", model: "claude-custom-v1", effort: "high"))
        XCTAssertEqual(runner.checkCount, 3, "the earlier check, then the turn's check and its one retry; choosing the effort does not check again")
        XCTAssertEqual(runner.turnCount, 1)
    }

    // MARK: - API-key billing

    /// For Codex the sign-in check is the only thing that refuses API-key billing, and a check that cannot finish
    /// must not wave an API-key setup through: `codex exec` would bill the key. Refused, but not as signed out.
    func testACodexAPIKeySetupWhoseCheckTimesOutRunsNoTurn() {
        for script in [[timesOut], [codexAPIKey, timesOut]] {
            let runner = CheckRunner(script, turn: CheckRunner.codexReply)
            let service = service(runner)
            if script.count > 1 {
                XCTAssertFalse(service.status("codex").ready, "the check that finished found an API key")
                clock = clock.addingTimeInterval(ProviderService.signedOutLifetime + 1)
            }
            XCTAssertThrowsError(try service.generate(MessageRequest(provider: "codex", message: "Hi"))) { error in
                let failure = error as? ProviderFailure
                XCTAssertEqual(failure?.cause, .providerUnavailable, "a busy Mac is not reported as signed out")
                XCTAssertEqual(failure?.sentence(), "Couldn't check ChatGPT's sign-in just now — the Mac may be busy. Try again in a moment.")
            }
            XCTAssertEqual(runner.turnCount, 0, "no `codex exec` ran for \(script.count == 1 ? "an unchecked" : "an API-key") setup")
        }
    }

    /// Claude's own API-key check on /message reads the finished turn, after it was billed, so an unchecked
    /// Claude sign-in is held to the same rule.
    func testAClaudeAPIKeySetupWhoseCheckTimesOutRunsNoTurn() {
        for script in [[timesOut], [claudeAPIKey, timesOut]] {
            let runner = CheckRunner(script)
            let service = service(runner)
            if script.count > 1 {
                XCTAssertFalse(service.status("claude").ready)
                clock = clock.addingTimeInterval(ProviderService.signedOutLifetime + 1)
            }
            XCTAssertThrowsError(try service.generate(MessageRequest(provider: "claude", message: "Hi"))) { error in
                XCTAssertEqual((error as? ProviderFailure)?.cause, .providerUnavailable)
                XCTAssertEqual((error as? ProviderFailure)?.sentence(), "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment.")
            }
            XCTAssertEqual(runner.turnCount, 0)
        }
    }

    /// Only a subscription sign-in this Mac confirmed lets a turn go ahead unchecked, and a check that cannot
    /// finish does not replace it: the next unknown is tried too, and a finished sign-out ends it.
    func testAnUnknownCheckDoesNotReplaceTheLastFinishedAnswer() {
        let runner = CheckRunner([chatGPT, timesOut, timesOut, timesOut, timesOut, { ProcessResult(status: 1, stdout: "", stderr: "Not logged in") }, timesOut],
                                 turn: CheckRunner.codexReply)
        let service = service(runner)
        XCTAssertTrue(service.status("codex").ready)
        for _ in 0..<2 {
            clock = clock.addingTimeInterval(ProviderService.signedInLifetime + 1)
            let status = service.status("codex")
            XCTAssertFalse(status.checked)
            XCTAssertTrue(status.ready, "this Mac confirmed a ChatGPT sign-in earlier")
        }
        XCTAssertFalse(service.status("codex").ready, "a finished sign-out replaces it")
        clock = clock.addingTimeInterval(ProviderService.signedOutLifetime + 1)
        XCTAssertFalse(service.status("codex").ready, "and an unknown after it is not tried")
    }

    // MARK: - Health and /status

    func testHealthSaysTheSignInCouldNotBeChecked() {
        let health = confirmedEarlier(CheckRunner([signedIn, timesOut])).health("claude")
        XCTAssertEqual(health, ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "2.1.274", usage: .unknown, signInChecked: false))
        XCTAssertEqual(health.json["signInChecked"] as? Bool, false)
        XCTAssertEqual(health.json["signedIn"] as? Bool, true, "a turn is tried, and older apps read `signedIn: false` as signed out")
        let unconfirmed = service(CheckRunner([timesOut])).health("claude")
        XCTAssertEqual(unconfirmed, ProviderHealth(installed: true, signedIn: true, account: "", cliVersion: "2.1.274", usage: .unknown, signInChecked: false),
                       "no turn is tried, but a Mac nobody could check is not shown as signed out; `signInChecked` says why")
        let checked = service(CheckRunner([signedIn])).health("claude")
        XCTAssertNil(checked.json["signInChecked"], "a finished check adds nothing to the 0.2.5 shape")
        let signedOutHealth = service(CheckRunner([signedOut])).health("claude")
        XCTAssertFalse(signedOutHealth.signedIn, "a check that finished and said so is still signed out")
        XCTAssertNil(signedOutHealth.json["signInChecked"])
    }

    /// Apps show `signedIn` and `/status`'s `ready` as they stand: false is the "not signed in" card and the sign-in
    /// command. Only a finished sign-out, or a missing CLI, is shown that way; whether a turn runs is `ready`'s job.
    func testOnlyAFinishedSignOutIsShownAsSignedOut() {
        XCTAssertTrue(ProviderStatus.unknown("claude", tried: false).shownSignedIn)
        XCTAssertTrue(ProviderStatus.unknown("codex", tried: true).shownSignedIn)
        XCTAssertFalse(service(CheckRunner([signedOut])).status("claude").shownSignedIn)
        XCTAssertFalse(service(CheckRunner([claudeAPIKey])).status("claude").shownSignedIn)
        XCTAssertFalse(service(CheckRunner([codexAPIKey])).status("codex").shownSignedIn)
        XCTAssertTrue(service(CheckRunner([signedIn])).status("claude").shownSignedIn)
        let missing = ProviderService(runner: CheckRunner([signedIn]), executableLookup: { _ in nil }).status("claude")
        XCTAssertFalse(missing.shownSignedIn, "a missing CLI is not shown as signed in")
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
        XCTAssertFalse(early.checked)
        XCTAssertFalse(early.ready, "nothing has confirmed a subscription sign-in yet, so no turn is tried on it")
        XCTAssertTrue(early.shownSignedIn, "a check that is merely slow is not shown as signed out")
        XCTAssertTrue(service.health("claude", signIn: early).signedIn)
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

    // MARK: - When the helper starts

    /// `iris-bridge serve` starts both checks as it launches, without waiting for them, so the app's first poll and
    /// the first message find an answer that already finished (and a subscription sign-in confirmed) instead of
    /// starting a cold check of their own.
    func testStartingTheSignInChecksRunsBothWithoutWaitingAndTheFirstReadFindsTheirAnswers() {
        let gate = DispatchSemaphore(value: 0)
        let bothSignedIn: CheckRunner.Answer = {
            gate.wait()
            return ProcessResult(status: 0, stdout: #"{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}"#, stderr: "Logged in using ChatGPT")
        }
        let runner = CheckRunner([bothSignedIn])
        let service = service(runner)
        let started = Date()
        service.startSignInChecks()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the helper does not wait for a CLI before it answers")
        let running = expectation(description: "both checks running")
        DispatchQueue.global().async { while runner.checkCount < 2 { Thread.sleep(forTimeInterval: 0.01) }; running.fulfill() }
        wait(for: [running], timeout: 5)
        XCTAssertEqual(Set(runner.checkedProviders), ["claude", "codex"], "both providers are checked side by side")
        gate.signal(); gate.signal()
        let claude = service.status("claude"), codex = service.status("codex")
        XCTAssertTrue(claude.checked && claude.ready); XCTAssertTrue(codex.checked && codex.ready)
        XCTAssertEqual(runner.checkCount, 2, "the first reads joined the checks started at launch")
        XCTAssertTrue(service.status("claude", wait: 0).ready, "a poll that cannot wait finds the finished answer")
        XCTAssertEqual(runner.checkCount, 2)
    }

    /// Waits, off the main thread, until `condition` holds.
    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let done = expectation(description: what)
        DispatchQueue.global().async { while !condition() { Thread.sleep(forTimeInterval: 0.01) }; done.fulfill() }
        wait(for: [done], timeout: timeout)
    }

    // MARK: - A check that never finishes

    /// A check can be stuck: a CLI the Mac never schedules, or one whose output something else keeps open. Nothing
    /// waits on it past its deadline (`signInWaitLimit` from its start), and it keeps running: no second check
    /// starts beside it, and its answer is kept when it does finish.
    func testAMessageWaitsForAStuckCheckNoLongerThanTheLimit() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([{ gate.wait(); return try signedIn() }])
        let service = service(runner)
        service.signInWait = 0.5
        let started = Date()
        XCTAssertThrowsError(try service.generate(MessageRequest(provider: "claude", message: "Hello"))) { error in
            XCTAssertEqual((error as? ProviderFailure)?.cause, .providerUnavailable, "nothing confirmed a subscription sign-in, and a busy Mac is not signed out")
            XCTAssertEqual((error as? ProviderFailure)?.sentence(), "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(runner.turnCount, 0)
        let again = Date()
        let status = service.status("claude")
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.4, "past its deadline a stuck check is not waited on again")
        XCTAssertFalse(status.checked)
        XCTAssertEqual(runner.checkCount, 1, "the stuck check keeps running and no second one starts beside it")
        gate.signal()
        eventually("the check finished") { service.status("claude", wait: 0).checked }
        XCTAssertTrue(service.status("claude").ready, "its answer is kept when it does finish")
        XCTAssertEqual(runner.checkCount, 1)
    }

    /// A real `claude auth status` stand-in that answers and exits at once, but leaves a detached process holding its
    /// output. The check finishes with the answer, as soon as the CLI exits and not when that process does.
    func testASignInCheckWhoseCLILeavesSomethingHoldingItsOutputStillFinishes() throws {
        let leftBehind = LeftBehind()
        defer { leftBehind.stop() }
        let claude = try StubCLI.write("""
            case "$1" in
              auth) echo '{"loggedIn":true,"subscriptionType":"max","authMethod":"claude.ai"}'; \(leftBehind.command); exit 0;;
            esac
            exit 1
            """)
        let service = ProviderService(runner: ForegroundProcessRunner(), executableLookup: { $0 == "claude" ? claude : nil })
        let started = Date()
        let status = service.status("claude")
        XCTAssertLessThan(Date().timeIntervalSince(started), ForegroundProcessRunner.drainGrace + 3)
        XCTAssertTrue(status.checked); XCTAssertTrue(status.ready)
        XCTAssertEqual(status.plan, "Max")
        XCTAssertTrue(leftBehind.isRunning, "the detached process was still holding the output")
    }

    func testAStuckCheckIsTriedWhenTheMacConfirmedASubscriptionEarlier() throws {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([signedIn, { gate.wait(); return try timesOut() }])
        let service = confirmedEarlier(runner)
        service.signInWait = 0.5
        let started = Date()
        let output = try service.generate(MessageRequest(provider: "claude", message: "Hello"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(output["reply"] as? String, "Ready")
        XCTAssertEqual(runner.turnCount, 1)
        gate.signal()
    }

    // MARK: - /status waits once

    func testStatusesShareOneWaitForBothProviders() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([{ gate.wait(); return try signedIn() }])
        let service = service(runner)
        let started = Date()
        let answers = service.statuses(["claude", "codex"], wait: 0.5)
        let took = Date().timeIntervalSince(started)
        XCTAssertLessThan(took, 0.9, "one wait for both providers, not one each")
        XCTAssertEqual(Set(answers.keys), ["claude", "codex"])
        XCTAssertEqual(answers["claude"]?.checked, false); XCTAssertEqual(answers["codex"]?.checked, false)
        XCTAssertEqual(answers["claude"]?.shownSignedIn, true)
        XCTAssertEqual(Set(runner.checkedProviders), ["claude", "codex"], "both checks started before either was waited for")
        gate.signal(); gate.signal()
    }

    // MARK: - The CLI version

    func testTheCLIVersionsAreReadAsTheHelperStarts() {
        let runner = CheckRunner([signedIn])
        let service = ProviderService(runner: runner, executableLookup: { "/iris-test/\($0)" }, catalogLookup: catalog, now: { [unowned self] in clock })
        service.startSignInChecks()
        eventually("both versions read") { runner.versionReads == 2 }
        let health = service.health("claude", signIn: service.status("claude"), versionWait: 0)
        XCTAssertEqual(health.cliVersion, "2.1.274", "the first poll finds the version without waiting for it")
        XCTAssertEqual(runner.versionReads, 2)
    }

    /// 0.2.6 as reviewed kept a version read that timed out as "" for good, so a busy Mac at launch showed no CLI
    /// version until the CLI itself changed.
    func testAVersionReadThatDoesNotFinishIsAskedAgain() {
        let runner = CheckRunner([signedIn])
        runner.answerVersions([timesOut, { ProcessResult(status: 0, stdout: "2.1.274 (Claude Code)", stderr: "") }])
        let service = service(runner)
        XCTAssertEqual(service.health("claude").cliVersion, "", "nothing to show yet")
        XCTAssertEqual(service.health("claude").cliVersion, "2.1.274", "the next read asks again")
        XCTAssertEqual(service.health("claude").cliVersion, "2.1.274")
        XCTAssertEqual(runner.versionReads, 2, "a version that was read is kept")
    }

    func testAStatusPollDoesNotWaitForAVersionPastItsOneWait() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([signedIn])
        runner.answerVersions([{ gate.wait(); return ProcessResult(status: 0, stdout: "2.1.274 (Claude Code)", stderr: "") }])
        let service = service(runner)
        let started = Date()
        let signIn = service.statuses(["claude"], wait: 0.3)["claude"]!
        let health = service.health("claude", signIn: signIn, versionWait: 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertEqual(health.cliVersion, "", "no version yet, and no second wait for it")
        XCTAssertTrue(health.signedIn)
        gate.signal()
        eventually("the version arrives") { service.health("claude", signIn: signIn, versionWait: 0).cliVersion == "2.1.274" }
        XCTAssertEqual(runner.versionReads, 1)
    }

    // MARK: - /models while a check runs

    func testAModelListDoesNotWaitOutAStuckCheck() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([{ gate.wait(); return try signedIn() }])
        var lookups = 0
        let service = service(runner, catalogLookup: { lookups += 1; return try catalog($0, $1) })
        service.modelsWait = 0.3
        let started = Date()
        let list = service.models("claude")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "well inside the app's 30-second /models timeout")
        XCTAssertTrue(list.models.isEmpty)
        XCTAssertEqual(list.source, "unavailable")
        XCTAssertEqual(list.notice, "Couldn't check Claude's sign-in just now — the Mac may be busy. Try again in a moment.")
        XCTAssertEqual(lookups, 0, "no CLI is started for a list while the sign-in is unknown")
        gate.signal()
    }

    func testAModelListWhileACheckRunsIsTheLastListOnceASubscriptionWasConfirmed() {
        let gate = DispatchSemaphore(value: 0)
        let runner = CheckRunner([signedIn, { gate.wait(); return try signedIn() }])
        var lookups = 0
        let service = service(runner, catalogLookup: { lookups += 1; return try catalog($0, $1) })
        let live = service.models("claude")
        XCTAssertEqual(live.models.map(\.id), ["claude-custom-v1"])
        clock = clock.addingTimeInterval(ProviderService.signedInLifetime + 1)
        service.modelsWait = 0.3
        let started = Date()
        let earlier = service.models("claude")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(earlier.models, live.models, "the list this Mac gave last")
        XCTAssertEqual(earlier.defaultModelID, "claude-custom-v1")
        XCTAssertEqual(earlier.source, "cached-test")
        XCTAssertEqual(earlier.notice, "Couldn't check Claude's sign-in just now — the Mac may be busy. These are the model choices from earlier.")
        XCTAssertEqual(lookups, 1)
        gate.signal()
    }
}
