import XCTest
@testable import IrisBridgeCore

final class DeviceStoreTests: XCTestCase {
    private func makeStore() -> DeviceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DeviceStore(file: dir.appendingPathComponent("devices.json"))
    }
    func testIssueStoresHashNotToken() throws {
        let store = makeStore()
        let (device, token) = try store.issue(name: "Chey's iPhone", platform: "iphone")
        XCTAssertEqual(token.count, 43)
        XCTAssertFalse(token.contains("="))
        XCTAssertEqual(device.tokenHash, DeviceStore.hash(token))
        let raw = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(raw.contains(token))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int, 0o600)
    }
    func testAuthenticateAndTouch() throws {
        var now = Date(timeIntervalSince1970: 100)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DeviceStore(file: dir.appendingPathComponent("devices.json"), now: { now })
        let (device, token) = try store.issue(name: "Mac", platform: "mac")
        now = Date(timeIntervalSince1970: 200)
        let found = store.authenticate(token: token)
        XCTAssertEqual(found?.id, device.id)
        XCTAssertEqual(found?.lastSeenAt, now)
        XCTAssertNil(store.authenticate(token: "nope"))
    }
    func testRevokeAndReload() throws {
        let store = makeStore()
        let (device, token) = try store.issue(name: "Mac", platform: "mac")
        XCTAssertTrue(try store.revoke(id: device.id))
        XCTAssertFalse(try store.revoke(id: device.id))
        XCTAssertNil(store.authenticate(token: token))
        let reloaded = DeviceStore(file: store.file)
        XCTAssertTrue(reloaded.all.isEmpty)
    }

    /// An app that polls `/status` with its token every few seconds must not rewrite devices.json on every poll.
    func testLastSeenIsWrittenAtMostOnceAMinute() throws {
        var now = Date(timeIntervalSince1970: 100)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DeviceStore(file: dir.appendingPathComponent("devices.json"), now: { now })
        let (_, token) = try store.issue(name: "Phone", platform: "iphone")
        let written = try Data(contentsOf: store.file)
        now = Date(timeIntervalSince1970: 130)
        XCTAssertEqual(store.authenticate(token: token)?.lastSeenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try Data(contentsOf: store.file), written)
        now = Date(timeIntervalSince1970: 160)
        XCTAssertEqual(store.authenticate(token: token)?.lastSeenAt, Date(timeIntervalSince1970: 160))
        XCTAssertNotEqual(try Data(contentsOf: store.file), written)
    }
}
