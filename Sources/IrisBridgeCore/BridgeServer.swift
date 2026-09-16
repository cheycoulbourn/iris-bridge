import Foundation
import Network
import Security

public final class BridgeServer: @unchecked Sendable {
    /// Ceiling on connections the listener will hold at once. `newConnectionLimit` is a budget that the
    /// framework spends as it delivers connections, so `release` tops it back up as connections close.
    private static let maximumConnections = 16
    /// How long a peer may sit on an accepted connection without finishing a request.
    private static let receiveTimeout: TimeInterval = 30
    /// How long the listener may stay in .waiting before `start()` gives up on it.
    private static let startTimeout: TimeInterval = 10

    /// Per-connection bookkeeping. Every field is touched only on `queue`, which is serial and is also the
    /// queue the listener, the connection state handler and the receive completions run on.
    private final class ConnectionState {
        var finished = false
        var released = false
    }

    private let listener: NWListener
    private let router: Router
    private let log: BridgeLog?
    private let queue = DispatchQueue(label: "iris-bridge.server")
    private let work = DispatchQueue(label: "iris-bridge.work", attributes: .concurrent)
    public private(set) var actualPort: UInt16?
    private let requestedPort: UInt16
    private var activeConnections = 0

    public init(port: UInt16, identity: BridgeIdentity, router: Router, serviceName: String, advertise: Bool, log: BridgeLog?) throws {
        self.router = router; self.log = log; self.requestedPort = port
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.secIdentity) else { throw CertificateError.importFailed(-1) }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionLimit = Self.maximumConnections
        if advertise {
            listener.service = NWListener.Service(name: serviceName, type: "_iris-bridge._tcp", domain: nil,
                                                  txtRecord: NWTXTRecord(["v": "2", "fp": identity.fingerprint, "name": serviceName]))
        }
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let attemptedPort = requestedPort
        var failure: Error?
        var waitingError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.actualPort = self?.listener.port?.rawValue; ready.signal()
            case .failed(let error): failure = error; ready.signal()
            case .waiting(let error):
                // .waiting is not by itself fatal: a listener can pass through it and reach .ready a moment
                // later (a network interface still coming up, for instance). Only a port that is taken or
                // forbidden can never resolve itself, so those fail at once and everything else gets the
                // grace period below, then fails with what the system actually said.
                if Self.isUnusablePort(error) { failure = Self.portInUse(attemptedPort); ready.signal() }
                else { waitingError = error }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + Self.startTimeout) == .timedOut {
            let reason = waitingError.map { $0.localizedDescription } ?? "it did not finish starting."
            listener.cancel()
            throw BridgeError.message("Iris Bridge could not start listening on port \(attemptedPort): \(reason)")
        }
        if let failure {
            // A busy port usually arrives as .failed(POSIXErrorCode: 48 Address already in use) rather than
            // .waiting, so both routes give the same friendly instruction.
            throw Self.isAddressInUse(failure) ? Self.portInUse(attemptedPort) : failure
        }
        // Once the listener is up, failures are asynchronous and would otherwise be silent: the helper would
        // sit there answering nothing. Exit instead so launchd's KeepAlive restarts a healthy copy.
        // .waiting is not that: a listener that has already served can drop into .waiting when an interface
        // goes away and come back to .ready by itself, so it gets logged loudly and nothing more. Quitting
        // on a transient wait would tear down every connection in flight for a problem that fixes itself.
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log?.error("listener failed: \(error)")
                exit(1)
            case .waiting(let error):
                self?.log?.error("listener waiting: \(error)")
            // A wait that resolves has to say so, or the log shows only the alarm and never the all-clear.
            case .ready: self?.log?.info("listener ready again")
            case .cancelled: self?.log?.info("listener cancelled")
            default: break
            }
        }
        log?.info("listening on \(actualPort ?? 0)")
    }

    private static func portInUse(_ port: UInt16) -> Error {
        BridgeError.message("Iris Bridge could not use port \(port). Another copy may be running; run `iris-bridge uninstall` or close the old helper, then try again.")
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if let error = error as? NWError, case .posix(.EADDRINUSE) = error { return true }
        return "\(error)".contains("Address already in use")
    }

    /// A port nobody can bind: already taken, or one this user is not allowed to use. Waiting longer on
    /// either of these only delays the same failure.
    private static func isUnusablePort(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .EADDRINUSE || code == .EACCES { return true }
        let text = "\(error)"
        return text.contains("Address already in use") || text.contains("Permission denied")
    }

    public func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        let parser = HTTPRequestParser()
        let context = Self.context(for: connection)
        let state = ConnectionState()
        activeConnections += 1
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed: self?.release(state); connection.cancel()
            case .cancelled: self?.release(state)
            default: break
            }
        }
        connection.start(queue: queue)
        // Covers the receive phase only. A peer that completes TLS and then says nothing would otherwise pin
        // the connection forever. `finished` is set the moment the request is in hand, so a slow generate is
        // never cut short.
        queue.asyncAfter(deadline: .now() + Self.receiveTimeout) { [weak self] in
            guard let self, !state.finished else { return }
            self.log?.info("closing idle connection from \(context.sourceAddress)")
            connection.cancel()
        }
        receive(connection, parser: parser, context: context, state: state)
    }

    /// Gives one connection's slot back to the listener. Idempotent: `.failed` is followed by `.cancelled`.
    private func release(_ state: ConnectionState) {
        guard !state.released else { return }
        state.released = true
        state.finished = true
        activeConnections = max(0, activeConnections - 1)
        listener.newConnectionLimit = Self.maximumConnections - activeConnections
    }

    private func receive(_ connection: NWConnection, parser: HTTPRequestParser, context: RequestContext, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { state.finished = true; self.log?.error("receive failed: \(error)"); connection.cancel(); return }
            switch parser.feed(data ?? Data()) {
            case .needMore:
                if complete { state.finished = true; connection.cancel() }
                else { self.receive(connection, parser: parser, context: context, state: state) }
            case .invalid(let reason):
                state.finished = true
                self.log?.info("invalid request from \(context.sourceAddress): \(reason)")
                self.reply(connection, HTTPResponse(status: 400, error: "Bad request"))
            case .tooLarge:
                state.finished = true
                self.reply(connection, HTTPResponse(status: 413, error: "This message is too large. Attach fewer files."))
            case .complete(let request):
                state.finished = true
                self.work.async {
                    let response = self.router.handle(request, context: context)
                    self.reply(connection, response)
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    static func context(for connection: NWConnection) -> RequestContext {
        var address = "unknown"
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let v4): address = "\(v4)"
            case .ipv6(let v6): address = "\(v6)"
            case .name(let name, _): address = name
            @unknown default: break
            }
        }
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        let loopback = bare.hasPrefix("127.") || bare == "::1" || bare.hasPrefix("::ffff:127.")
        return RequestContext(sourceAddress: bare, isLoopback: loopback)
    }
}
