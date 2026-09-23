import XCTest
@testable import IrisBridgeCore

final class BridgePathsTests: XCTestCase {
    func testPrepareCreatesPrivateFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = BridgePaths(root: base.appendingPathComponent("support"), logs: base.appendingPathComponent("logs"))
        try paths.prepare()
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.root.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logs.path))
    }
    /// Everything 0.3.0 keeps sits under the support folder, so `uninstall` still removes all of it.
    func testTheV3FilesLiveUnderTheRoot() {
        let paths = BridgePaths(root: URL(fileURLWithPath: "/tmp/root"), logs: URL(fileURLWithPath: "/tmp/logs"))
        XCTAssertEqual(paths.events.path, "/tmp/root/events")
        XCTAssertEqual(paths.snapshots.path, "/tmp/root/snapshots")
        XCTAssertEqual(paths.actions.path, "/tmp/root/actions.json")
        XCTAssertEqual(paths.sessionIndex.path, "/tmp/root/sessions/index.json")
        XCTAssertEqual(paths.sessionWorkspace.path, "/tmp/root/sessions/workspace")
    }

    func testWritePrivateSetsMode600() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = BridgePaths(root: base, logs: base)
        try paths.prepare()
        try BridgePaths.writePrivate(Data("x".utf8), to: paths.adminToken)
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.adminToken.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int), 0o600)
    }
    func testLogRotatesAtLimit() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("bridge.log")
        let log = BridgeLog(file: file, maxBytes: 200)
        for i in 0..<20 { log.info("line \(i) padded to make it long enough to rotate") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".1"))
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 200 + 80)
    }
    func testErrorLinesAreTagged() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("bridge.log")
        BridgeLog(file: file).error("boom")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(" ERROR boom"))
    }
}
