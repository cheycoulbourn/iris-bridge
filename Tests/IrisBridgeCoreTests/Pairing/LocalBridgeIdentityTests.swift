import XCTest
import Darwin
@testable import IrisBridgeCore

final class LocalBridgeIdentityTests: XCTestCase {
    private var root: URL!
    private let pin = String(repeating: "ab", count: 32)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private var directory: URL { root.appendingPathComponent("IrisBridge") }
    private var file: URL { directory.appendingPathComponent("local-identity.json") }

    func testWritesOnlyPublicPinPrivatelyAndUpdatesAtomically() throws {
        try LocalBridgeIdentity.write(fingerprint: pin.uppercased(), groupContainer: root)
        let descriptor = try JSONDecoder().decode(LocalBridgeIdentity.Descriptor.self, from: Data(contentsOf: file))
        XCTAssertEqual(descriptor.version, 1); XCTAssertEqual(descriptor.fingerprint, pin)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "fingerprint"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let next = String(repeating: "cd", count: 32)
        try LocalBridgeIdentity.write(fingerprint: next, groupContainer: root)
        XCTAssertEqual(try JSONDecoder().decode(LocalBridgeIdentity.Descriptor.self, from: Data(contentsOf: file)).fingerprint, next)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["local-identity.json"])
    }
    func testMissingGroupAndWrongOwnerAndUnsafePermissionsAreRefused() throws {
        XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: pin, groupContainer: root.appendingPathComponent("missing")))
        XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: pin, groupContainer: root, expectedOwner: geteuid() + 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: pin, groupContainer: root))
    }
    func testSymlinkGroupAndChildAndFileCannotRedirectWrites() throws {
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("group-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: pin, groupContainer: link))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: pin, groupContainer: root))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outside = target.appendingPathComponent("unchanged")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: pin, groupContainer: root))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["unchanged"])
    }
    func testInvalidPinDoesNotCreateDescriptor() {
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(try LocalBridgeIdentity.write(fingerprint: invalid, groupContainer: root))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
