import Foundation
import Network
import Security

public final class BridgeServer: @unchecked Sendable {
    private let listener: NWListener
    private let router: Router
    private let log: BridgeLog?
    private let queue = DispatchQueue(label: "iris-bridge.server")
    private let work = DispatchQueue(label: "iris-bridge.work", attributes: .concurrent)
    public private(set) var actualPort: UInt16?
    private let requestedPort: UInt16

    public init(port: UInt16, identity: BridgeIdentity, router: Router, serviceName: String, advertise: Bool, log: BridgeLog?) throws {
        self.router = router; self.log = log; self.requestedPort = port
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.secIdentity) else { throw CertificateError.importFailed(-1) }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        if advertise {
            listener.service = NWListener.Service(name: serviceName, type: "_iris-bridge._tcp", domain: nil,
                                                  txtRecord: NWTXTRecord(["v": "2", "fp": identity.fingerprint, "name": serviceName]))
        }
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let attemptedPort = requestedPort
        var failure: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.actualPort = self?.listener.port?.rawValue; ready.signal()
            case .failed(let error): failure = error; ready.signal()
            case .waiting: failure = BridgeError.message("Iris Bridge could not use port \(attemptedPort). Another copy may be running; run `iris-bridge uninstall` or close the old helper, then try again."); ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        ready.wait()
        if let failure { throw failure }
        log?.info("listening on \(actualPort ?? 0)")
    }

    public func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        let parser = HTTPRequestParser()
        let context = Self.context(for: connection)
        connection.stateUpdateHandler = { state in if case .failed = state { connection.cancel() } }
        connection.start(queue: queue)
        receive(connection, parser: parser, context: context)
    }

    private func receive(_ connection: NWConnection, parser: HTTPRequestParser, context: RequestContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.log?.error("receive failed: \(error)"); connection.cancel(); return }
            switch parser.feed(data ?? Data()) {
            case .needMore:
                if complete { connection.cancel() } else { self.receive(connection, parser: parser, context: context) }
            case .invalid(let reason):
                self.log?.info("invalid request from \(context.sourceAddress): \(reason)")
                self.reply(connection, HTTPResponse(status: 400, error: "Bad request"))
            case .tooLarge:
                self.reply(connection, HTTPResponse(status: 413, error: "This message is too large. Attach fewer files."))
            case .complete(let request):
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
