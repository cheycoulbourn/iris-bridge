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
    func testParsesPutAndSplitsTheQueryFromTheRoute() {
        let parser = HTTPRequestParser()
        guard case .complete(let r) = parser.feed(Data("PUT /context HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "PUT"); XCTAssertEqual(r.route, "/context"); XCTAssertTrue(r.query.isEmpty)

        let query = HTTPRequest(method: "GET", path: "/inbox?since=2026-09-16T10%3A00%3A00Z&status=all&flag&=skip", headers: [:], body: Data())
        XCTAssertEqual(query.route, "/inbox")
        XCTAssertEqual(query.query["since"], "2026-09-16T10:00:00Z")
        XCTAssertEqual(query.query["status"], "all")
        XCTAssertEqual(query.query["flag"], "")
        XCTAssertEqual(query.query.count, 3)
    }
    func testRejectsOversizedBody() {
        let parser = HTTPRequestParser(maxBody: 10)
        guard case .tooLarge = parser.feed(Data("POST /m HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8)) else { return XCTFail() }
    }
    func testDefaultBodyCapMatchesThePlannerSnapshotLimit() {
        XCTAssertEqual(HTTPRequestParser.maximumBodyBytes, 16 * 1024 * 1024)
        let parser = HTTPRequestParser()
        let raw = "PUT /context HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n"
        guard case .tooLarge = parser.feed(Data(raw.utf8)) else { return XCTFail() }
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
        XCTAssertTrue(text.contains("Content-Length: \(response.body.count)\r\n"))
        let serialized = response.serialized()
        let blankLine = serialized.range(of: Data("\r\n\r\n".utf8))!
        XCTAssertEqual(serialized[blankLine.upperBound...], response.body)
    }
    func testBodySplitAcrossChunksAndTerminatorSplit() {
        let parser = HTTPRequestParser()
        let raw = "POST /m HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789"
        let data = Data(raw.utf8)
        let terminatorSplit = data.range(of: Data("\r\n\r\n".utf8))!.lowerBound + 3
        guard case .needMore = parser.feed(data.prefix(terminatorSplit)) else { return XCTFail() }
        guard case .needMore = parser.feed(Data("\n01234".utf8)) else { return XCTFail() }
        guard case .complete(let request) = parser.feed(Data("56789".utf8)) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST"); XCTAssertEqual(request.path, "/m")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "0123456789")
    }
    func testHeaderCapAppliesWhenTerminatorArrivesInSameChunk() {
        let parser = HTTPRequestParser()
        let prefix = "GET /status HTTP/1.1\r\nX-Pad: "
        let padding = String(repeating: "a", count: 70_000 - prefix.utf8.count - 4)
        let raw = prefix + padding + "\r\n\r\n"
        XCTAssertEqual(raw.utf8.count, 70_000)
        guard case .invalid = parser.feed(Data(raw.utf8)) else { return XCTFail() }
    }
}
