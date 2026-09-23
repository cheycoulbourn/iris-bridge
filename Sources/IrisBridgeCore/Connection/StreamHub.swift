import Foundation

/// Where the listener hands a connection once it has been upgraded to a WebSocket.
public protocol StreamEndpoint: AnyObject {
    func attach(_ socket: WebSocketConnection)
}

/// How the rest of the helper reaches the connected apps.
public protocol StreamOutbox: AnyObject {
    /// Every authenticated device.
    func broadcast(_ message: JSONValue)
    /// One authenticated device, the one that said hello most recently. False when none is connected.
    @discardableResult func sendToOne(_ message: JSONValue) -> Bool
    var hasClients: Bool { get }
}

/// What the hub asks of the helper once a device is authenticated. `BridgeStreams` is the real one.
public protocol StreamHandler: AnyObject {
    /// `hello.ok`, built when the device has proved who it is.
    func helloOK(for device: PairedDevice) -> JSONValue
    /// Right after `hello.ok`: replay from the cursors, then anything still waiting for an answer. What it
    /// sends before it returns reaches the device ahead of anything broadcast meanwhile.
    func connected(device: PairedDevice, cursors: [String: Int], send: @escaping (JSONValue) -> Void)
    func received(_ message: AppMessage, from device: PairedDevice)
    /// The device's last stream closed.
    func disconnected(device: PairedDevice)
}

/// Authenticates each stream on its first message (spec §10), keeps the authenticated ones, and fans
/// messages out to them. A stream never sees anything before it has proved it belongs to a paired device.
///
/// A device that has just said hello is greeted first: `hello.ok`, then the handler's replay. Until that is
/// queued, what `broadcast` and `sendToOne` address to it is held and follows the greeting in order, so a live
/// event never reaches a device ahead of (or in the middle of) the replay it has to come after.
public final class StreamHub: StreamEndpoint, StreamOutbox, @unchecked Sendable {
    private struct Client {
        var socket: WebSocketConnection
        var device: PairedDevice
        var helloAt: Date
        /// While the client is being greeted, what was addressed to it meanwhile; nil once it is live.
        var held: [Data]?
    }

    private let devices: DeviceStore
    private let log: BridgeLog?
    private let helloTimeout: TimeInterval
    private let lock = NSLock()
    private var waiting: [UUID: WebSocketConnection] = [:]
    private var clients: [UUID: Client] = [:]
    /// Held strongly: the listener keeps the hub, and the hub keeps everything the stream reaches.
    public var handler: StreamHandler?

    public init(devices: DeviceStore, log: BridgeLog?, helloTimeout: TimeInterval = 10) {
        self.devices = devices; self.log = log; self.helloTimeout = helloTimeout
    }

    public func attach(_ socket: WebSocketConnection) {
        lock.lock(); waiting[socket.id] = socket; lock.unlock()
        socket.onText = { [weak self, weak socket] data in
            guard let self, let socket else { return }
            self.received(data, on: socket)
        }
        socket.onClose = { [weak self, weak socket] in
            guard let self, let socket else { return }
            self.closed(socket)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + helloTimeout) { [weak self, weak socket] in
            guard let self, let socket else { return }
            self.lock.lock(); let stillWaiting = self.waiting[socket.id] != nil; self.lock.unlock()
            if stillWaiting {
                self.log?.info("stream from \(socket.context.sourceAddress) sent no hello; closing it")
                socket.close(.noHello)
            }
        }
    }

    public var hasClients: Bool { lock.lock(); defer { lock.unlock() }; return !clients.isEmpty }

    public func broadcast(_ message: JSONValue) {
        deliver(message.encoded(), to: current())
    }

    @discardableResult public func sendToOne(_ message: JSONValue) -> Bool {
        guard let newest = current().max(by: { $0.helloAt < $1.helloAt }) else { return false }
        deliver(message.encoded(), to: [newest])
        return true
    }

    /// Sends to the live clients and holds the message for any still being greeted. The choice between the
    /// two is made under the lock, the same lock `finishGreeting` flushes under, so nothing sent after a
    /// client goes live can overtake what was held for it.
    private func deliver(_ data: Data, to targets: [Client]) {
        var live: [WebSocketConnection] = []
        lock.lock()
        for target in targets {
            guard let client = clients[target.socket.id] else { continue }
            if client.held != nil { clients[target.socket.id]?.held?.append(data) } else { live.append(client.socket) }
        }
        lock.unlock()
        for socket in live { socket.send(data) }
    }

    /// Clients whose device is still paired. A revoked device's streams are closed here, so revocation
    /// takes effect on the next message in either direction.
    private func current() -> [Client] {
        lock.lock()
        let all = Array(clients.values)
        lock.unlock()
        let paired = Set(devices.all.map(\.id))
        for client in all where !paired.contains(client.device.id) {
            log?.info("device \(client.device.id) was revoked; closing its stream")
            client.socket.close(.deviceRevoked)
        }
        return all.filter { paired.contains($0.device.id) }
    }

    private func received(_ data: Data, on socket: WebSocketConnection) {
        lock.lock()
        let isWaiting = waiting[socket.id] != nil
        let client = clients[socket.id]
        lock.unlock()
        if isWaiting { hello(data, on: socket); return }
        guard let client else { return }
        guard devices.all.contains(where: { $0.id == client.device.id }) else { socket.close(.deviceRevoked); return }
        let message: AppMessage
        do { message = try AppMessage.decode(data) } catch {
            log?.info("stream message from device \(client.device.id) could not be read; ignored")
            return
        }
        if case .unknown(let type) = message { log?.info("stream message type \(type) is not one this helper knows; ignored"); return }
        handler?.received(message, from: client.device)
    }

    private func hello(_ data: Data, on socket: WebSocketConnection) {
        guard case .hello(let hello)? = try? AppMessage.decode(data) else {
            log?.info("stream from \(socket.context.sourceAddress) did not start with hello; closing it")
            socket.close(.badFirstMessage); return
        }
        guard hello.protocol == StreamProtocol.version else { socket.close(.protocolMismatch); return }
        guard let device = devices.authenticate(token: hello.deviceToken) else {
            log?.info("stream from \(socket.context.sourceAddress) refused: that device token is not paired here")
            socket.close(.deviceRevoked); return
        }
        lock.lock()
        waiting[socket.id] = nil
        clients[socket.id] = Client(socket: socket, device: device, helloAt: Date(), held: [])
        lock.unlock()
        log?.info("stream open for device \(device.id)")
        // No lock is held while the handler runs: `connected` takes locks whose holders broadcast.
        if let handler {
            socket.send(handler.helloOK(for: device).encoded())
            handler.connected(device: device, cursors: hello.cursors ?? [:]) { [weak socket] message in socket?.send(message.encoded()) }
        }
        finishGreeting(socket)
    }

    /// The greeting has been queued: send what was held, in order, and let later messages go straight out.
    /// `send` only queues a write on the server's serial queue, so doing it under the lock is cheap, and it
    /// keeps a broadcast that sees the client live from being queued ahead of the held messages.
    private func finishGreeting(_ socket: WebSocketConnection) {
        lock.lock(); defer { lock.unlock() }
        guard let held = clients[socket.id]?.held else { return }
        for data in held { socket.send(data) }
        clients[socket.id]?.held = nil
    }

    private func closed(_ socket: WebSocketConnection) {
        lock.lock()
        waiting[socket.id] = nil
        let client = clients.removeValue(forKey: socket.id)
        let stillOpen = client.map { gone in clients.values.contains { $0.device.id == gone.device.id } } ?? true
        lock.unlock()
        if let client, !stillOpen {
            log?.info("stream closed for device \(client.device.id)")
            handler?.disconnected(device: client.device)
        }
    }
}
