import XCTest
@testable import IrisBridgeCore

final class WebSocketTests: XCTestCase {
    private func request(_ headers: [String: String], path: String = "/v3/stream", method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data())
    }
    private let upgrade = ["upgrade": "websocket", "connection": "keep-alive, Upgrade", "sec-websocket-version": "13",
                           "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ=="]

    /// Masks a client frame the way RFC 6455 §5.3 says, so tests can speak as the app does.
    private func clientFrame(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, key: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]) -> Data {
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        if payload.count < 126 { bytes.append(0x80 | UInt8(payload.count)) }
        else { bytes += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] }
        bytes += key
        bytes += payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
        return Data(bytes)
    }

    func testTheRFCExampleKeyGetsTheRFCExampleAccept() {
        XCTAssertEqual(WebSocketHandshake.accept(key: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    private func refusal(_ request: HTTPRequest) -> Int? {
        if case .refuse(let response) = WebSocketHandshake.answer(request) { return response.status }
        return nil
    }

    func testAValidUpgradeGets101AndEverythingElseAnError() throws {
        guard case .upgrade(let reply) = WebSocketHandshake.answer(request(upgrade)) else { return XCTFail("refused a valid upgrade") }
        let text = String(decoding: reply, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        var browser = upgrade; browser["origin"] = "https://evil.example"
        XCTAssertEqual(refusal(request(browser)), 403)
        for broken in [["upgrade": "h2c"], ["sec-websocket-version": "8"], ["sec-websocket-key": "short"]] {
            XCTAssertEqual(refusal(request(upgrade.merging(broken) { $1 })), 400, "\(broken)")
        }
        XCTAssertEqual(refusal(request(upgrade, method: "POST")), 400)
        XCTAssertTrue(WebSocketHandshake.wantsStream(request(upgrade)))
        XCTAssertTrue(WebSocketHandshake.wantsStream(request([:], path: "/v3/stream?x=1")))
        XCTAssertFalse(WebSocketHandshake.wantsStream(request(upgrade, path: "/status")))
    }

    func testTheRFCMaskedHelloReadsAsText() throws {
        var reader = WebSocketFrameReader()
        let frame = Data([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
        XCTAssertEqual(try reader.feed(frame), [.text(Data("Hello".utf8))])
    }

    func testFramesArrivingOneByteAtATimeStillRead() throws {
        var reader = WebSocketFrameReader()
        var events: [WebSocketFrameReader.Event] = []
        for byte in clientFrame(0x1, Array("{\"type\":\"hello\"}".utf8)) { events += try reader.feed(Data([byte])) }
        XCTAssertEqual(events, [.text(Data("{\"type\":\"hello\"}".utf8))])
    }

    func testFragmentsJoinAndAPingBetweenThemIsAnswered() throws {
        var reader = WebSocketFrameReader()
        let data = clientFrame(0x1, Array("Hel".utf8), fin: false) + clientFrame(0x9, Array("p".utf8)) + clientFrame(0x0, Array("lo".utf8))
        XCTAssertEqual(try reader.feed(data), [.ping(Data("p".utf8)), .text(Data("Hello".utf8))])
    }

    func testLongLengthsCloseAndBinary() throws {
        var reader = WebSocketFrameReader()
        let long = [UInt8](repeating: 0x61, count: 300)
        XCTAssertEqual(try reader.feed(clientFrame(0x1, long)), [.text(Data(long))])
        XCTAssertEqual(try reader.feed(clientFrame(0x2, [1, 2])), [.binary])
        XCTAssertEqual(try reader.feed(clientFrame(0x8, [0x03, 0xE8])), [.close(code: 1000)])
        XCTAssertEqual(try reader.feed(clientFrame(0x8, [])), [.close(code: nil)])
    }

    func testProtocolErrorsAndOversizedMessagesAreRefused() {
        var unmasked = WebSocketFrameReader()
        XCTAssertThrowsError(try unmasked.feed(Data([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]))) {
            XCTAssertEqual($0 as? WebSocketFrameReader.Failure, .protocolError("unmasked client frame"))
        }
        var orphan = WebSocketFrameReader()
        XCTAssertThrowsError(try orphan.feed(clientFrame(0x0, [1])))
        var small = WebSocketFrameReader(maximumMessageBytes: 10)
        XCTAssertThrowsError(try small.feed(clientFrame(0x1, Array(repeating: 0x61, count: 11)))) {
            XCTAssertEqual($0 as? WebSocketFrameReader.Failure, .tooLarge)
        }
        var fragmentedTooBig = WebSocketFrameReader(maximumMessageBytes: 10)
        XCTAssertThrowsError(try fragmentedTooBig.feed(clientFrame(0x1, Array(repeating: 0x61, count: 6), fin: false) + clientFrame(0x0, Array(repeating: 0x61, count: 6))))
        var reserved = WebSocketFrameReader()
        XCTAssertThrowsError(try reserved.feed(Data([0xC1, 0x80, 0, 0, 0, 0])), "RSV1 means an extension nobody agreed to")
    }

    func testServerFramesAreUnmaskedWithTheRightLengthForm() {
        XCTAssertEqual(WebSocketFrameWriter.text(Data("Hello".utf8)), Data([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]))
        let medium = WebSocketFrameWriter.text(Data(count: 256))
        XCTAssertEqual(Array(medium.prefix(4)), [0x81, 126, 0x01, 0x00])
        let large = WebSocketFrameWriter.text(Data(count: 70_000))
        XCTAssertEqual(Array(large.prefix(10)), [0x81, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70])
        XCTAssertEqual(WebSocketFrameWriter.close(.deviceRevoked), Data([0x88, 0x02, 0x11, 0x31]))
    }
}
