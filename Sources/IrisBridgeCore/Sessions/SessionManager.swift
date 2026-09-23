import Foundation

/// One live provider session per thread (spec §6.3): started when the app opens the thread, one message per
/// turn, resumed by the provider's session id, stopped after 15 idle minutes, at most three turns answering at
/// once across the Mac. Every turn event goes to the thread's event log, then to every connected app.
public final class SessionManager: TurnContextProvider, @unchecked Sendable {
    public struct Limits {
        public var activeTurns: Int
        public var idle: TimeInterval
        /// Claude processes kept warm at once; the least recently used idle one stops to make room.
        public var liveSessions: Int
        public static let standard = Limits(activeTurns: 3, idle: 15 * 60, liveSessions: 6)
        public init(activeTurns: Int, idle: TimeInterval, liveSessions: Int) { self.activeTurns = activeTurns; self.idle = idle; self.liveSessions = liveSessions }
    }

    private struct Turn { var id: String; var mentions: Set<String>; var commandConnectors: Set<String> }

    private struct ThreadState {
        var provider: Provider
        var session: ProviderSession?
        var token = UUID()
        var turn: Turn?
        var lastUsed: Date
        /// A resumed session that has not completed a turn yet: if it fails as `internal`, the saved id is
        /// forgotten so the thread is not stuck resuming a conversation Claude no longer has.
        var unproven = false
    }

    private let adapters: [Provider: ProviderAdapter]
    private let events: EventLog
    private let index: SessionIndex
    private let log: BridgeLog?
    private let limits: Limits
    private let now: () -> Date
    private let queue = DispatchQueue(label: "iris-bridge.sessions")
    private var threads: [String: ThreadState] = [:]
    private var connectors = ConnectorTable()
    private var timer: DispatchSourceTimer?

    public weak var outbox: StreamOutbox?
    public weak var approvals: ApprovalBroker?
    /// Checked before a turn starts; a failure here (signed out, not installed) is the turn's answer.
    public var readiness: (Provider) -> ProviderFailure? = { _ in nil }
    /// Everything sessions learn that Health reports: commands and connectors, usage, and each turn's outcome.
    public var observer: ((Provider, ProviderEvent) -> Void)?

    public init(adapters: [ProviderAdapter], events: EventLog, index: SessionIndex, log: BridgeLog?,
                limits: Limits = .standard, now: @escaping () -> Date = Date.init) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        self.events = events; self.index = index; self.log = log; self.limits = limits; self.now = now
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.stopIdleSessions() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - From the app

    public func open(_ message: AppMessage.ThreadOpen) {
        guard StreamIdentifiers.isThreadID(message.threadId) else { return }
        queue.async {
            var state = self.threads[message.threadId] ?? ThreadState(provider: message.provider, lastUsed: self.now())
            state.lastUsed = self.now()
            self.threads[message.threadId] = state
            // `thread.open` carries no effort: a later `thread.send` that names one restarts this warm session
            // if it differs (canReuse), so the cold start here never needs to guess it.
            guard state.turn == nil, !self.canReuse(state, provider: message.provider, model: message.model, effort: nil) else { return }
            _ = try? self.startSession(message.threadId, provider: message.provider, model: message.model, effort: nil)
        }
    }

    public func send(_ message: AppMessage.ThreadSend) {
        guard StreamIdentifiers.isThreadID(message.threadId), StreamIdentifiers.isToken(message.turnId) else {
            log?.info("a thread.send without a valid thread or turn id was ignored")
            return
        }
        queue.async { self.start(message) }
    }

    public func cancel(_ message: AppMessage.TurnCancel) {
        queue.async {
            guard let state = self.threads[message.threadId], state.turn?.id == message.turnId else { return }
            self.approvals?.endTurn(threadId: message.threadId, turnId: message.turnId)
            state.session?.cancel()
        }
    }

    public func replay(threadId: String, after cursor: Int) -> [JSONValue] {
        events.replay(threadId: threadId, after: cursor)
    }

    public func turnContext(threadId: String) -> TurnContext? {
        queue.sync {
            guard let state = threads[threadId], let turn = state.turn else { return nil }
            return TurnContext(threadId: threadId, turnId: turn.id, provider: state.provider, mentions: turn.mentions,
                               commandConnectors: turn.commandConnectors, connectors: connectors)
        }
    }

    // MARK: - Turns

    private func start(_ message: AppMessage.ThreadSend) {
        let threadId = message.threadId
        if let problem = message.problem() {
            return fail(threadId, message.turnId, ProviderFailure(cause: .badRequest, provider: message.provider.rawValue, message: problem))
        }
        var state = threads[threadId] ?? ThreadState(provider: message.provider, lastUsed: now())
        if state.turn != nil {
            return fail(threadId, message.turnId, ProviderFailure(cause: .busy, provider: message.provider.rawValue,
                                                                  message: "This chat is still answering. Stop it or wait for it to finish."))
        }
        if threads.values.filter({ $0.turn != nil }).count >= limits.activeTurns {
            return fail(threadId, message.turnId, ProviderFailure(cause: .busy, provider: message.provider.rawValue,
                                                                  message: "Three chats are already answering on your Mac. Try again when one finishes."))
        }
        if let failure = readiness(message.provider) { return fail(threadId, message.turnId, failure) }
        state.lastUsed = now()
        threads[threadId] = state
        let session: ProviderSession
        do {
            if canReuse(state, provider: message.provider, model: message.model, effort: message.effort), let current = state.session { session = current }
            else { session = try startSession(threadId, provider: message.provider, model: message.model, effort: message.effort) }
        } catch {
            return fail(threadId, message.turnId, error as? ProviderFailure ?? ProviderFailure(cause: .internal, provider: message.provider.rawValue,
                                                                                               details: error.localizedDescription))
        }
        threads[threadId]?.turn = Turn(id: message.turnId, mentions: Set(message.mentions ?? []),
                                       commandConnectors: Set(message.command?.kind == "iris" ? message.command?.connectors ?? [] : []))
        publish(threadId, message.turnId, .started(provider: message.provider, model: message.model ?? session.model ?? "default",
                                                   sessionId: session.sessionId ?? ""))
        do {
            try session.send(TurnRequest(turnId: message.turnId, text: IrisPrompt.turnText(message), images: IrisPrompt.images(message)))
        } catch {
            threads[threadId]?.session = nil
            finish(threadId, message.turnId, .failed(error as? ProviderFailure ?? ProviderFailure(cause: .internal, provider: message.provider.rawValue,
                                                                                                 details: error.localizedDescription)))
        }
    }

    /// An omitted `effort` (nil) makes no claim either way and reuses whatever is running, exactly like an
    /// omitted `model`; a given `effort` that differs from the running session's own forces a restart.
    private func canReuse(_ state: ThreadState, provider: Provider, model: String?, effort: String?) -> Bool {
        guard let session = state.session, state.provider == provider else { return false }
        if let model, model != session.model { return false }
        if let effort, effort != session.effort { return false }
        return provider == .codex || session.isLive
    }

    @discardableResult
    private func startSession(_ threadId: String, provider: Provider, model: String?, effort: String?) throws -> ProviderSession {
        guard let adapter = adapters[provider] else {
            throw ProviderFailure(cause: .providerUnavailable, provider: provider.rawValue, message: "This Mac cannot run \(provider.displayName).")
        }
        threads[threadId]?.session?.stop()
        makeRoom(for: threadId)
        let token = UUID()
        let resume = index.sessionId(threadId: threadId, provider: provider)
        let session = try adapter.session(threadId: threadId, resume: resume, model: model, effort: effort) { [weak self] event in
            self?.queue.async { self?.handle(threadId, provider, token, event) }
        }
        if let id = session.sessionId { index.set(id, threadId: threadId, provider: provider) }
        var state = threads[threadId] ?? ThreadState(provider: provider, lastUsed: now())
        state.provider = provider; state.session = session; state.token = token; state.unproven = resume != nil
        threads[threadId] = state
        log?.info("\(provider.rawValue) session \(resume == nil ? "started" : "resumed") for thread \(threadId)")
        return session
    }

    /// Stops the least recently used idle Claude process when the Mac already keeps the most it should.
    private func makeRoom(for threadId: String) {
        let live = threads.filter { $0.key != threadId && $0.value.session?.isLive == true }
        guard live.count >= limits.liveSessions,
              let oldest = live.filter({ $0.value.turn == nil }).min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        oldest.value.session?.stop()
        threads[oldest.key]?.session = nil
    }

    /// Runs every minute: a session idle for `limits.idle` stops, and resumes from the provider's saved
    /// conversation on its next message.
    func stopIdleSessions() {
        queue.async {
            for (threadId, state) in self.threads where state.turn == nil && state.session != nil
                && self.now().timeIntervalSince(state.lastUsed) > self.limits.idle {
                state.session?.stop()
                self.threads[threadId]?.session = nil
                self.log?.info("stopped the idle session for thread \(threadId)")
            }
        }
    }

    // MARK: - From the provider

    private func handle(_ threadId: String, _ provider: Provider, _ token: UUID, _ event: ProviderEvent) {
        let current = threads[threadId]?.token == token
        switch event {
        case .turn(let turnId, let turnEvent):
            guard current, threads[threadId]?.turn?.id == turnId else { return }
            if turnEvent.isTerminal { finish(threadId, turnId, turnEvent) } else { publish(threadId, turnId, turnEvent) }
        case .session(let id):
            if current { index.set(id, threadId: threadId, provider: provider) }
        case .catalog(_, let table):
            connectors = table
        case .usage:
            break
        case .ended:
            if current { threads[threadId]?.session = nil }
        }
        observer?(provider, event)
    }

    private func finish(_ threadId: String, _ turnId: String, _ event: TurnEvent) {
        guard let state = threads[threadId] else { return }
        threads[threadId]?.turn = nil
        threads[threadId]?.lastUsed = now()
        switch event {
        case .completed:
            threads[threadId]?.unproven = false
        case .failed(let failure) where failure.cause == .internal && state.unproven:
            index.set(nil, threadId: threadId, provider: state.provider)
            threads[threadId]?.session?.stop()
            threads[threadId]?.session = nil
            log?.info("thread \(threadId) could not resume its \(state.provider.rawValue) conversation; the next message starts a new one")
        default:
            break
        }
        approvals?.endTurn(threadId: threadId, turnId: turnId)
        publish(threadId, turnId, event)
    }

    /// A turn that never started: only `turn.failed` goes out.
    private func fail(_ threadId: String, _ turnId: String, _ failure: ProviderFailure) {
        publish(threadId, turnId, .failed(failure))
    }

    private func publish(_ threadId: String, _ turnId: String, _ event: TurnEvent) {
        guard let message = events.append(threadId: threadId, event.message(threadId: threadId, turnId: turnId)) else { return }
        outbox?.broadcast(message)
    }
}
