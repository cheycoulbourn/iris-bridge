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
