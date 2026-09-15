import XCTest
@testable import IrisBridgeCore

final class LaunchAgentTests: XCTestCase {
    func testPlistRunsServeAtLoadAndKeepsAlive() throws {
        let text = LaunchAgent.plist(binary: "/Users/me/Library/Application Support/Iris Bridge/bin/iris-bridge")
        let plist = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, "com.agentcy.iris-bridge")
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], ["/Users/me/Library/Application Support/Iris Bridge/bin/iris-bridge", "serve"])
        XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist?["KeepAlive"] as? Bool, true)
        XCTAssertTrue((plist?["StandardOutPath"] as? String ?? "").hasSuffix("Iris Bridge/launchd.log"))
    }
}
