import XCTest
@testable import IrisBridgeCore

final class CertificateTests: XCTestCase {
    func testGeneratesOnceAndFingerprintIsStable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = BridgePaths(root: base, logs: base)
        try paths.prepare()
        let first = try CertificateManager.load(paths: paths)
        XCTAssertEqual(first.fingerprint.count, 64)
        XCTAssertTrue(first.fingerprint.allSatisfy(\.isHexDigit))
        let second = try CertificateManager.load(paths: paths)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        let keyMode = try FileManager.default.attributesOfItem(atPath: paths.privateKey.path)[.posixPermissions] as? Int
        XCTAssertEqual(keyMode, 0o600)
        XCTAssertEqual(try CertificateManager.fingerprint(pem: first.certificatePEM), first.fingerprint)
    }
}
