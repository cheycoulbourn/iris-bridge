import Foundation
import Network

/// One upgraded connection: frames in and out over the NWConnection the listener already accepted. Every
/// callback runs on `queue`, the server's serial queue; `send` and `close` may be called from anywhere.
public final class WebSocketConnection: @unchecked Sendable {
    /// How often the helper pings, and how long a connection may stay silent (no frame of any kind) before
    /// it is closed: a phone that sleeps without closing its socket must not hold a slot forever.
    static let pingInterval: TimeInterval = 25
    static let silenceLimit: TimeInterval = 70

    public let id = UUID()
    public let context: RequestContext
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log: BridgeLog?
    private var reader = WebSocketFrameReader()
    private var lastHeard = Date()
    private var closed = false
    private var timer: DispatchSourceTimer?

    /// A complete text message. Set before `start`.
    var onText: ((Data) -> Void)?
    /// Called once, whoever closed it.
    var onClose: (() -> Void)?

    init(connection: NWConnection, context: RequestContext, queue: DispatchQueue, log: BridgeLog?) {
        self.connection = connection; self.context = context; self.queue = queue; self.log = log
    }

    /// Reads `initial` (bytes that arrived with the upgrade request), then the network.
    func start(initial: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            if !initial.isEmpty { consume(initial) }
            receive()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func send(_ text: Data) {
        queue.async { self.write(WebSocketFrameWriter.text(text)) }
    }

    public func close(_ code: WebSocketCloseCode) {
        queue.async { self.shutDown(code) }
    }

    private func write(_ frame: Data) {
        guard !closed else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error != nil || complete { self.shutDown(nil); return }
            if !self.closed { self.receive() }
        }
    }

    private func consume(_ data: Data) {
        lastHeard = Date()
        do {
            for event in try reader.feed(data) {
                switch event {
                case .text(let message): onText?(message)
                case .ping(let payload): write(WebSocketFrameWriter.frame(.pong, payload))
                case .pong: break
                case .binary: shutDown(.unsupportedData)
                case .close: shutDown(.normal)
                }
                if closed { return }
            }
        } catch WebSocketFrameReader.Failure.tooLarge {
            shutDown(.tooLarge)
        } catch {
            log?.info("stream from \(context.sourceAddress) broke the WebSocket protocol: \(error)")
            shutDown(.protocolError)
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
            log?.info("stream from \(context.sourceAddress) went silent; closing it")
            shutDown(.goingAway)
        } else {
            write(WebSocketFrameWriter.frame(.ping, Data()))
        }
    }

    /// Sends a close frame when there is a code to send, then lets the socket go. Idempotent.
    private func shutDown(_ code: WebSocketCloseCode?) {
        guard !closed else { return }
        if let code { connection.send(content: WebSocketFrameWriter.close(code), completion: .contentProcessed { _ in }) }
        closed = true
        timer?.cancel(); timer = nil
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        let onClose = self.onClose
        self.onClose = nil; self.onText = nil
        onClose?()
    }
}
