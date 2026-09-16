import XCTest
@testable import IrisBridgeCore

final class CommandLineTests: XCTestCase {
    func testDefaultsToServeWhenNothingIsTyped() throws {
        let line = try BridgeCommandLine.parse([])
        XCTAssertEqual(line.command, "serve")
        XCTAssertEqual(try line.port(default: 48731), 48731)
        XCTAssertTrue(line.positionals.isEmpty)
    }

    func testRejectsNonNumericPort() {
        XCTAssertThrowsError(try BridgeCommandLine.parse(["serve", "--port", "abc"]).port(default: 48731)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("--port"), "\(error)")
        }
    }

    func testRejectsOutOfRangePort() {
        XCTAssertThrowsError(try BridgeCommandLine.parse(["serve", "--port", "70000"]).port(default: 48731))
        XCTAssertThrowsError(try BridgeCommandLine.parse(["serve", "--port", "0"]).port(default: 48731))
        XCTAssertThrowsError(try BridgeCommandLine.parse(["serve", "--port", "-1"]).port(default: 48731))
    }

    func testRejectsTrailingPortWithNoValue() {
        XCTAssertThrowsError(try BridgeCommandLine.parse(["serve", "--port"])) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("--port"), "\(error)")
        }
    }

    func testRejectsOptionWhoseValueIsAnotherOption() {
        XCTAssertThrowsError(try BridgeCommandLine.parse(["serve", "--root", "--no-bonjour"]))
    }

    func testRevokeTakesTheFirstNonFlagArgumentAsTheId() throws {
        let line = try BridgeCommandLine.parse(["revoke", "--root", "/tmp/x", "abc"])
        XCTAssertEqual(line.command, "revoke")
        XCTAssertEqual(line.options["--root"], "/tmp/x")
        XCTAssertEqual(line.positionals, ["abc"])
        XCTAssertEqual(line.positionals.first, "abc")
    }

    func testRevokeIdIsFoundBeforeAndAfterFlags() throws {
        XCTAssertEqual(try BridgeCommandLine.parse(["revoke", "abc", "--root", "/tmp/x"]).positionals.first, "abc")
        XCTAssertEqual(try BridgeCommandLine.parse(["revoke", "--no-bonjour", "abc"]).positionals.first, "abc")
    }

    func testUnknownOptionIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(try BridgeCommandLine.parse(["status", "--prot", "48797"]))
        XCTAssertThrowsError(try BridgeCommandLine.parse(["status", "--root /tmp/x --port 48797"]))
    }

    func testFlagsAndEqualsFormAreUnderstood() throws {
        let line = try BridgeCommandLine.parse(["serve", "--root=/tmp/x", "--port=48797", "--no-bonjour"])
        XCTAssertEqual(line.options["--root"], "/tmp/x")
        XCTAssertEqual(try line.port(default: 48731), 48797)
        XCTAssertTrue(line.flags.contains("--no-bonjour"))
    }

    func testPortValueIsNotMistakenForAPositional() throws {
        let line = try BridgeCommandLine.parse(["revoke", "--port", "48797"])
        XCTAssertTrue(line.positionals.isEmpty)
    }
}
