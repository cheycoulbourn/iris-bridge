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

    // `uninstall` deletes a whole folder, so the check that decides whether a folder is ours has to be
    // exercised directly: the real one is never run on a developer's account.
    func testFolderWithAMarkerLooksLikeOurs() throws {
        let folder = try makeTemporaryFolder()
        for marker in ["admin-token", "certificate.pem", "devices.json"] {
            let copy = try makeTemporaryFolder()
            try Data("x".utf8).write(to: copy.appendingPathComponent(marker))
            XCTAssertTrue(LaunchAgent.looksLikeBridgeFolder(copy), "expected \(marker) to identify the folder")
        }
        try Data("x".utf8).write(to: folder.appendingPathComponent("admin-token"))
        XCTAssertTrue(LaunchAgent.looksLikeBridgeFolder(folder))
    }

    func testEmptyOrUnrelatedFolderDoesNotLookLikeOurs() throws {
        let empty = try makeTemporaryFolder()
        XCTAssertFalse(LaunchAgent.looksLikeBridgeFolder(empty))
        try Data("x".utf8).write(to: empty.appendingPathComponent("Taxes.numbers"))
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        XCTAssertFalse(LaunchAgent.looksLikeBridgeFolder(empty))
    }

    func testMissingFolderAndPlainFileDoNotLookLikeOurs() throws {
        let folder = try makeTemporaryFolder()
        XCTAssertFalse(LaunchAgent.looksLikeBridgeFolder(folder.appendingPathComponent("nope")))
        let file = folder.appendingPathComponent("admin-token")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(LaunchAgent.looksLikeBridgeFolder(file))
        XCTAssertFalse(LaunchAgent.looksLikeBridgeFolder(URL(fileURLWithPath: "/")))
    }

    private func makeTemporaryFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-bridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
