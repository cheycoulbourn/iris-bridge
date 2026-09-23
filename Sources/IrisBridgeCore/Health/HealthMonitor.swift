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

    /// Checks again soon, off the caller's thread; sends `health.changed` when anything changed.
    public func refresh() { queue.async { self.check() } }

    /// The last health object, without asking any CLI.
    public func report() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return makeReport()
    }

    /// Why a turn cannot start, when the last check already knows: not installed, or signed out.
    public func readiness(_ provider: Provider) -> ProviderFailure? {
        lock.lock(); defer { lock.unlock() }
        guard let known = health[provider] else { return nil }
        let name = provider == .claude ? "Claude Code" : "Codex"
        if !known.installed { return ProviderFailure(cause: .providerUnavailable, provider: provider.rawValue, message: "Install \(name) on your Mac first.") }
        if !known.signedIn { return ProviderFailure(cause: .signedOut, provider: provider.rawValue, details: status[provider]?.message) }
        return nil
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
            freshStatus[provider] = providers.status(provider.rawValue)
            freshHealth[provider] = providers.health(provider.rawValue)
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
