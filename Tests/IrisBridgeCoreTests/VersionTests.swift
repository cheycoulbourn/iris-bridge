import XCTest
@testable import IrisBridgeCore

final class VersionTests: XCTestCase {
    func testVersionIsSemver() {
        let parts = BridgeVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
        XCTAssertEqual(BridgeVersion.protocolVersion, 2)
    }
}
