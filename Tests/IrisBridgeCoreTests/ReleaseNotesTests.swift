import XCTest
@testable import IrisBridgeCore

/// CHANGELOG.md's 0.3.0 entry is what the owner reads to decide what Iris builds without the new chat (139 to
/// 141) get from this helper. Each claim it makes about them is checked here against the code that decides it.
final class ReleaseNotesTests: XCTestCase {
    /// The 0.3.0 entry, with line breaks and indentation folded to single spaces so a wrapped phrase still matches.
    private func entry(_ version: String = "0.3.0") throws -> String {
        let changelog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let heading = "## \(version)\n"
        let start = try XCTUnwrap(text.range(of: heading), "CHANGELOG.md has no \(version) entry").upperBound
        let end = text.range(of: "\n## ", range: start..<text.endIndex)?.lowerBound ?? text.endIndex
        return text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Older builds received agent work only through these tools. The entry names every one, and none is served.
    /// (RouterTests checks that `POST /admin/inbox` and `GET /admin/context`, the routes behind them, answer 404.)
    func testTheEntryNamesEveryReplacedToolAndTheRoutesBehindThem() throws {
        let entry = try entry()
        for gone in ["iris_submit_post", "iris_submit_series", "iris_propose_archive_posts", "iris_revise_submission",
                     "iris_list_submissions", "iris_get_workspace_context"] {
            XCTAssertNil(IrisToolCatalog.tool(named: gone), "\(gone) is still served")
            XCTAssertTrue(entry.contains("`\(gone)`"), "the 0.3.0 entry does not say \(gone) is gone")
        }
        XCTAssertTrue(entry.contains("`POST /admin/inbox`"))
        XCTAssertTrue(entry.contains("`GET /admin/context`"))
        XCTAssertFalse(entry.localizedCaseInsensitiveContains("keep working unchanged"),
                       "older builds stop receiving agent work, so they do not keep working unchanged")
    }

    /// A change made with the v3 tools waits for a `/v3/stream` hello, which only a build with the new chat sends,
    /// for as long as `ActionRelay.keep`.
    func testTheEntrySaysHowLongAChangeWaitsForABuildWithTheNewChat() throws {
        let entry = try entry()
        XCTAssertEqual(ActionRelay.keep, 7 * 24 * 60 * 60)
        XCTAssertTrue(entry.contains("after a week is dropped"))
        XCTAssertTrue(entry.contains("`/v3/stream`"))
    }

    /// `/status` sends a paired device every capability, new ones included; the entry must not say otherwise.
    func testTheEntrySaysWhatStatusNowAdvertisesToAPairedOlderBuild() throws {
        let entry = try entry()
        for added in ["v3", "effort"] {
            XCTAssertTrue(BridgeVersion.capabilities.contains(added), "\(added) is no longer advertised")
            XCTAssertTrue(entry.contains("`\(added)`"), "the 0.3.0 entry does not say `\(added)` is advertised")
        }
        XCTAssertEqual(BridgeVersion.protocolVersion, 2)
        XCTAssertTrue(entry.contains("`version: 2`"))
        XCTAssertFalse(entry.contains("never sees it advertised"))
    }

    /// `HealthMonitor.preAllowedTools()` reads the settings file for every report
    /// (HealthMonitorTests.testPreAllowedToolsAreReadAgainForEveryReportAndSentAtTheNextCheck).
    func testTheEntryDoesNotSayPreAllowedToolsAreReadOnce() throws {
        let entry = try entry()
        XCTAssertFalse(entry.contains("read once"))
        XCTAssertTrue(entry.contains("reads that file again every time it builds its health report"))
    }
}
