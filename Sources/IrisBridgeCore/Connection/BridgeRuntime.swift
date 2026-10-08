import Foundation

/// Everything `iris-bridge serve` runs, built in one place: the v2 router, and the v3 stream with its
/// sessions, tools, approvals and health (spec §4).
public final class BridgeRuntime {
    public let router: Router
    public let hub: StreamHub
    private let health: HealthMonitor
    private let sessions: SessionManager
    private let streams: BridgeStreams

    /// `helperBinary` is this executable, which chat sessions start as their `iris` MCP server. `generator` answers
    /// v2 `/message`; `providers` is the provider service it shares with v3 health, so both report the same usage.
    /// `executables` finds the CLIs and `launcher` starts them; tests pass stand-ins for both.
    public init(paths: BridgePaths, port: UInt16, fingerprint: String, hostName: String, adminToken: String, devices: DeviceStore,
                pairing: PairingCodeStore, inbox: InboxStore, context: ContextStore, log: BridgeLog?, helperBinary: String,
                generator: Generator, providers: ProviderService,
                executables: @escaping (String) -> String? = ProviderService.findExecutable,
                launcher: ProcessLauncher = SystemProcessLauncher(),
                claudeSettings: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")) {
        hub = StreamHub(devices: devices, log: log)
        health = HealthMonitor(providers: providers, settingsFile: claudeSettings)
        let claude = ClaudeAdapter(setup: ClaudeSetup(binary: { executables("claude") }, helperBinary: helperBinary,
                                                      root: paths.root, port: port, workingDirectory: paths.sessionWorkspace),
                                   launcher: launcher, health: { providers.health("claude") })
        let codex = CodexAdapter(setup: CodexSetup(binary: { executables("codex") }, helperBinary: helperBinary,
                                                   root: paths.root, port: port, workingDirectory: paths.sessionWorkspace),
                                 launcher: launcher, health: { providers.health("codex") })
        sessions = SessionManager(adapters: [claude, codex], events: EventLog(folder: paths.events), index: SessionIndex(file: paths.sessionIndex), log: log)
        let approvals = ApprovalBroker(turns: sessions, log: log)
        let relay = ActionRelay(file: paths.actions, log: log)
        let snapshots = SnapshotStore(folder: paths.snapshots, legacy: context)
        let tools = ToolService(reads: IrisReadTools(snapshots: snapshots, hasPairedDevices: { !devices.all.isEmpty }), relay: relay,
                                approvals: approvals, snapshots: snapshots, turns: sessions)
        router = Router(fingerprint: fingerprint, hostName: hostName, adminToken: adminToken, devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: generator, log: log, tools: tools, pairingURL: "https://\(HostName.localHostName()):\(port)")
        streams = BridgeStreams(sessions: sessions, approvals: approvals, relay: relay, snapshots: snapshots, health: health, log: log)
        let health = self.health
        sessions.outbox = hub; sessions.approvals = approvals
        sessions.readiness = { health.readiness($0) }
        sessions.observer = { health.observe($0, $1) }
        approvals.outbox = hub; relay.outbox = hub; health.outbox = hub
        hub.handler = streams
    }

    /// Starts the health checks; the listener is started by `BridgeServer`.
    public func start() { health.start() }
}
