import Foundation
import CryptoKit

/// The WebSocket upgrade for `/v3/stream` (RFC 6455 §4.2), answered on the helper's own TLS listener.
/// Network.framework's `NWProtocolWebSocket` cannot be used there: with it in a listener's stack, a plain
/// HTTP request gets no reply at all, which would break every v2 endpoint on port 48731 (probe, 2026-09-23).
/// So the listener keeps speaking HTTP, and a request for `/v3/stream` is upgraded here by hand.
public enum WebSocketHandshake {
    static let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`.
    public static func accept(key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
    }

    /// Whether this request asks for the stream at all. Such a request never reaches the v2 router.
    public static func wantsStream(_ request: HTTPRequest) -> Bool {
        request.route == StreamProtocol.path
    }

    public enum Answer {
        /// The `101 Switching Protocols` bytes; the connection is a WebSocket once they are sent.
        case upgrade(Data)
        case refuse(HTTPResponse)
    }

    /// No extension and no subprotocol is ever accepted, so an offered `permessage-deflate` is simply not
    /// taken up. A browser's request is refused exactly as the v2 router refuses one.
    public static func answer(_ request: HTTPRequest) -> Answer {
        if request.header("origin") != nil { return .refuse(HTTPResponse(status: 403, error: "Browser requests are not allowed.")) }
        let connection = (request.header("connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard request.method == "GET", request.body.isEmpty,
              request.header("upgrade")?.lowercased() == "websocket", connection.contains("upgrade"),
              request.header("sec-websocket-version") == "13",
              let key = request.header("sec-websocket-key"), Data(base64Encoded: key)?.count == 16 else {
            return .refuse(HTTPResponse(status: 400, error: "Bad request"))
        }
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept(key: key))\r\n\r\n"
        return .upgrade(Data(head.utf8))
    }
}

public enum WebSocketOpcode: UInt8 {
    case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
}

/// Close codes the helper sends. 1000–1011 are RFC 6455's; 4400–4426 are the stream's own (contract §1).
public enum WebSocketCloseCode: UInt16 {
    case normal = 1000, goingAway = 1001, protocolError = 1002, unsupportedData = 1003, tooLarge = 1009
    case badFirstMessage = 4400, deviceRevoked = 4401, noHello = 4408, protocolMismatch = 4426
}

/// Client frames in, messages out (RFC 6455 §5). Every client frame must be masked; fragments are joined;
/// control frames may arrive between fragments. Nothing here touches the network.
public struct WebSocketFrameReader {
    public enum Event: Equatable {
        case text(Data)
        case binary
        case ping(Data)
        case pong
        case close(code: UInt16?)
    }

    public enum Failure: Error, Equatable {
        case protocolError(String)
        case tooLarge
    }

    private var buffer: [UInt8] = []
    private var fragments: [UInt8]?
    private var fragmentIsText = false
    private let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = StreamLimits.maximumMessageBytes) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    /// Appends bytes and returns every complete message they finish. Throws on the first protocol error;
    /// the connection is then closed with 1002, or 1009 for `tooLarge`.
    public mutating func feed(_ data: Data) throws -> [Event] {
        buffer.append(contentsOf: data)
        var events: [Event] = []
        while let frame = try nextFrame() {
            if let event = try handle(frame) { events.append(event) }
        }
        return events
    }

    private struct Frame { var fin: Bool; var opcode: WebSocketOpcode; var payload: [UInt8] }

    private mutating func nextFrame() throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[0], second = buffer[1]
        guard first & 0x70 == 0 else { throw Failure.protocolError("reserved bits set") }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { throw Failure.protocolError("unknown opcode") }
        guard second & 0x80 != 0 else { throw Failure.protocolError("unmasked client frame") }
        var length = UInt64(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = buffer[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            guard length >> 63 == 0 else { throw Failure.protocolError("length too long") }
            offset = 10
        }
        let isControl = opcode.rawValue & 0x8 != 0
        if isControl {
            guard first & 0x80 != 0, length <= 125 else { throw Failure.protocolError("bad control frame") }
        } else {
            guard length + UInt64(fragments?.count ?? 0) <= UInt64(maximumMessageBytes) else { throw Failure.tooLarge }
        }
        guard buffer.count >= offset + 4 + Int(length) else { return nil }
        let mask = Array(buffer[offset..<offset + 4])
        let start = offset + 4
        var payload = Array(buffer[start..<start + Int(length)])
        for index in payload.indices { payload[index] ^= mask[index % 4] }
        buffer.removeFirst(start + Int(length))
        return Frame(fin: first & 0x80 != 0, opcode: opcode, payload: payload)
    }

    private mutating func handle(_ frame: Frame) throws -> Event? {
        switch frame.opcode {
        case .ping: return .ping(Data(frame.payload))
        case .pong: return .pong
        case .close:
            guard frame.payload.count != 1 else { throw Failure.protocolError("bad close payload") }
            let code = frame.payload.count >= 2 ? UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1]) : nil
            return .close(code: code)
        case .text, .binary:
            guard fragments == nil else { throw Failure.protocolError("new message inside a fragmented one") }
            if frame.fin { return frame.opcode == .text ? .text(Data(frame.payload)) : .binary }
            fragments = frame.payload
            fragmentIsText = frame.opcode == .text
            return nil
        case .continuation:
            guard var joined = fragments else { throw Failure.protocolError("continuation without a message") }
            joined.append(contentsOf: frame.payload)
            guard frame.fin else { fragments = joined; return nil }
            fragments = nil
            return fragmentIsText ? .text(Data(joined)) : .binary
        }
    }
}

/// Server frames: never masked, never fragmented.
public enum WebSocketFrameWriter {
    public static func frame(_ opcode: WebSocketOpcode, _ payload: Data) -> Data {
        var bytes: [UInt8] = [0x80 | opcode.rawValue]
        switch payload.count {
        case 0..<126: bytes.append(UInt8(payload.count))
        case 126...0xFFFF: bytes += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default: bytes.append(127); bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(payload.count) >> (UInt64($0) * 8)) }
        }
        return Data(bytes) + payload
    }

    public static func text(_ payload: Data) -> Data { frame(.text, payload) }

    public static func close(_ code: WebSocketCloseCode) -> Data {
        frame(.close, Data([UInt8(code.rawValue >> 8), UInt8(code.rawValue & 0xFF)]))
    }
}
