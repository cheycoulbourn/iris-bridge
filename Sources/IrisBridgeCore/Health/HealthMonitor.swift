import Foundation

/// What the app's Settings → Iris AI and error messages need to know about this Mac (spec §9.1, contract §6):
/// each provider's sign-in, plan, CLI version and usage, the Claude account's connectors and `/` commands, and
/// any Claude permission rule that would let a connector tool skip Iris's approval (spec §6.5). Kept current in
/// the background, so `hello.ok` never waits on a CLI.
public final class HealthMonitor: @unchecked Sendable {
    public static let interval: TimeInterval = 60

    private let providers: ProviderService
    private let settingsFile: URL
    private let queue = DispatchQueue(label: "iris-bridge.health")
    private let lock = NSLock()
    private var status: [Provider: ProviderStatus] = [:]
    private var health: [Provider: ProviderHealth] = [:]
    private var commands: JSONValue = []
    private var connectors = ConnectorTable()
    private var lastReport: JSONValue?
    /// A health round is queued and has not started yet. Every refresh asked for until it starts is that round.
    private var roundPending = false
    private var timer: DispatchSourceTimer?
    public weak var outbox: StreamOutbox?

    /// `settingsFile` is the owner's `~/.claude/settings.json`.
    public init(providers: ProviderService, settingsFile: URL) {
        self.providers = providers; self.settingsFile = settingsFile
    }

    /// Checks now, then every minute.
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        lock.lock(); self.timer = timer; lock.unlock()
    }

    /// Checks again soon, off the caller's thread; sends `health.changed` when anything changed. Requests coalesce:
    /// while a round is queued and has not started, asking again adds nothing, so a burst of refused sends is one
    /// more round rather than one each, run back to back behind a slow check. A request made while a round runs
    /// queues one more, so a change it was asked for is not missed.
    public func refresh() {
        lock.lock()
        guard !roundPending else { lock.unlock(); return }
        roundPending = true
        lock.unlock()
        queue.async {
            self.lock.lock(); self.roundPending = false; self.lock.unlock()
            self.check()
        }
    }

    /// The last health object, without asking any CLI.
    public func report() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return makeReport()
    }

    /// Why a turn cannot start, when the last check already knows: not installed, signed out, or a sign-in the
    /// Mac could not check and has not confirmed before. Only a check that finished is signed out. One that could
    /// not (a busy Mac) is tried when this Mac confirmed a subscription sign-in earlier: a Mac that really is
    /// signed out says so in the turn. Otherwise nothing has ruled out an API key, which a Codex run would bill
    /// (neither the environment nor the Codex adapter can tell), so it is refused, but not as signed out.
    /// Decided from the sign-in answer's `ready`, never from the report's `signedIn`: the report shows a sign-in
    /// nobody could check as signed in either way, so the app does not show a busy Mac as signed out.
    /// A refusal asks for a fresh check, so signing in on the Mac is picked up without waiting for the timer.
    public func readiness(_ provider: Provider) -> ProviderFailure? {
        lock.lock()
        guard let known = health[provider], let signIn = status[provider] else { lock.unlock(); return nil }
        let name = provider == .claude ? "Claude Code" : "Codex"
        let failure: ProviderFailure?
        if !known.installed { failure = ProviderFailure(cause: .providerUnavailable, provider: provider.rawValue, message: "Install \(name) on your Mac first.") }
        else if signIn.ready { failure = nil }
        else if signIn.checked { failure = ProviderFailure(cause: .signedOut, provider: provider.rawValue, details: signIn.message) }
        else { failure = ProviderFailure(cause: .providerUnavailable, provider: provider.rawValue, details: signIn.message, message: signIn.message) }
        lock.unlock()
        if failure != nil { refresh() }
        return failure
    }

    /// What sessions learn (`SessionManager.observer`).
    public func observe(_ provider: Provider, _ event: ProviderEvent) {
        switch event {
        case .catalog(let commands, let connectors):
            lock.lock(); self.commands = commands; self.connectors = connectors; lock.unlock()
            publishIfChanged()
        case .usage(let limited, let resetsAt):
            if limited { providers.recordTurn(provider.rawValue, failure: ProviderFailure(cause: .usageLimit, provider: provider.rawValue, resetsAt: resetsAt)) }
            refresh()
        case .turn(_, .completed):
            providers.recordTurn(provider.rawValue, failure: nil)
            refresh()
        case .turn(_, .failed(let failure)):
            providers.recordTurn(provider.rawValue, failure: failure)
            refresh()
        case .turn, .session, .ended:
            break
        }
    }

    private func check() {
        var freshStatus: [Provider: ProviderStatus] = [:], freshHealth: [Provider: ProviderHealth] = [:]
        for provider in Provider.allCases {
            // Health is built from the same answer, so a check that could not finish is not run twice. A check that
            // never finishes holds the round no longer than `ProviderService.signInWaitLimit` from its start.
            let signIn = providers.status(provider.rawValue)
            freshStatus[provider] = signIn
            freshHealth[provider] = providers.health(provider.rawValue, signIn: signIn)
        }
        lock.lock(); status = freshStatus; health = freshHealth; lock.unlock()
        publishIfChanged()
    }

    private func publishIfChanged() {
        lock.lock()
        let report = makeReport()
        let changed = report != lastReport
        lastReport = report
        lock.unlock()
        if changed { outbox?.broadcast(HelperMessage.healthChanged(report)) }
    }

    /// Contract §6. A provider nobody has checked yet reports what is known: nothing.
    private func makeReport() -> JSONValue {
        func entry(_ provider: Provider) -> [String: JSONValue] {
            let known = health[provider] ?? ProviderHealth(installed: false, signedIn: false, account: "", cliVersion: "", usage: .unknown)
            return (try? JSONValue.decode(JSONSerialization.data(withJSONObject: known.json, options: [.sortedKeys])))?.objectValue ?? [:]
        }
        var claude = entry(.claude)
        claude["connectors"] = connectors.json
        claude["commands"] = commands
        claude["preAllowedTools"] = .array(preAllowedTools().map { .string($0) })
        return ["helperVersion": .string(BridgeVersion.current), "checked": .bool(!health.isEmpty),
                "claude": .object(claude), "codex": .object(entry(.codex))]
    }

    /// `permissions.allow` rules in the owner's Claude settings that name an MCP tool: those tools never reach
    /// the approval tool (spike q2-g), so the app warns about them.
    func preAllowedTools() -> [String] {
        let settings = (try? Data(contentsOf: settingsFile)).flatMap { try? JSONValue.decode($0) }
        return (settings?["permissions"]?["allow"]?.arrayValue ?? []).compactMap(\.stringValue).filter { $0.hasPrefix("mcp__") }.sorted()
    }
}
