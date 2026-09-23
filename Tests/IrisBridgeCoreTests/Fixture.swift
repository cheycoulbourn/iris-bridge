import Foundation
@testable import IrisBridgeCore

/// Recorded provider output from Tests/IrisBridgeCoreTests/Fixtures. `<name>.stdout` and `<name>.stderr` are
/// each optional; a fixture has at least one. Fixtures/README.md says where each one came from.
enum Fixture {
    static func result(_ name: String, status: Int32 = 1) -> ProcessResult {
        func read(_ ext: String) -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        let stdout = read("stdout"), stderr = read("stderr")
        precondition(!stdout.isEmpty || !stderr.isEmpty, "No fixture called \(name) in Tests/IrisBridgeCoreTests/Fixtures")
        return ProcessResult(status: status, stdout: stdout, stderr: stderr)
    }
}
