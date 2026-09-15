import XCTest
@testable import IrisBridgeCore

final class MessageRequestTests: XCTestCase {
    func testUnknownProviderRejected() {
        XCTAssertThrowsError(try MessageValidation.parse(Data(#"{"provider":"anything","message":"hi"}"#.utf8))) { error in
            XCTAssertEqual(error as? BridgeError, .message("Choose Claude Code or Codex."))
        }
    }
    func testEmptyMessageRejected() {
        XCTAssertThrowsError(try MessageValidation.parse(Data(#"{"provider":"codex","message":"   "}"#.utf8)))
    }
    func testInvalidImageRejected() {
        let body = #"{"provider":"codex","message":"x","images":[{"mime":"image/jpeg","data":"bad%%%"}]}"#
        XCTAssertThrowsError(try MessageValidation.parse(Data(body.utf8)))
    }
    func testTooManyImagesRejected() {
        let image = #"{"mime":"image/png","data":"AA=="}"#
        let body = #"{"provider":"codex","message":"x","images":[\#(image),\#(image),\#(image),\#(image),\#(image)]}"#
        XCTAssertThrowsError(try MessageValidation.parse(Data(body.utf8))) { XCTAssertEqual($0 as? BridgeError, .message("Choose up to four images.")) }
    }
    func testValidRequestParses() throws {
        let request = try MessageValidation.parse(Data(#"{"id":"r1","provider":"claude","message":"Plan","planMode":true,"images":[{"mime":"image/png","data":"AA=="}]}"#.utf8))
        XCTAssertEqual(request.id, "r1"); XCTAssertEqual(request.provider, "claude"); XCTAssertEqual(request.planMode, true)
    }
}
