import XCTest
@testable import IrisBridgeCore

final class HTTPTests: XCTestCase {
    func testParsesRequestAcrossChunks() {
        let parser = HTTPRequestParser()
        let raw = "POST /message HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"message\":1}"
        let data = Data(raw.utf8)
        guard case .needMore = parser.feed(data.prefix(30)) else { return XCTFail() }
        guard case .complete(let request) = parser.feed(data.dropFirst(30)) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST"); XCTAssertEqual(request.path, "/message")
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{\"message\":1}")
    }
    func testGetWithoutBody() {
        let parser = HTTPRequestParser()
        guard case .complete(let r) = parser.feed(Data("GET /status HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "GET"); XCTAssertTrue(r.body.isEmpty)
    }
    func testRejectsOversizedBody() {
        let parser = HTTPRequestParser(maxBody: 10)
        guard case .tooLarge = parser.feed(Data("POST /m HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8)) else { return XCTFail() }
    }
    func testRejectsGarbage() {
        let parser = HTTPRequestParser()
        guard case .invalid = parser.feed(Data("not http\r\n\r\n".utf8)) else { return XCTFail() }
    }
    func testResponseSerialization() {
        let response = HTTPResponse(status: 401, error: "Pair this device again.")
        let text = String(data: response.serialized(), encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.hasSuffix("{\"error\":\"Pair this device again.\"}"))
    }
}
