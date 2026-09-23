import XCTest
@testable import IrisBridgeCore

/// The v2 Inbox store: what helper 0.2.x saved, served to older apps and to `iris-bridge inbox` until phase 6.
final class SubmissionsTests: XCTestCase {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testImportedWhitespacePunctuationAndLineBreaksSurviveDiskRoundTrip() throws {
        var submission = SavedInbox.post("sub_aaaaaaaaaaaa")
        submission.post?.hook = "  Keep this exactly…\n\nwith punctuation!  \t"
        submission.post?.script = "Line one.\r\nLine two;\n\n  trailing spaces  "
        submission.post?.caption = "Caption with \"quotes\" and apostrophe's."
        let store = SavedInbox.store([submission])
        _ = try store.decide(id: submission.id, status: .changesRequested, comment: nil)
        XCTAssertEqual(InboxStore(file: store.file).all(since: nil).first?.post, submission.post)
    }

    // MARK: decide

    func testDecideFlipsStatusAndSetsDecidedAt() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let submission = SavedInbox.post("sub_aaaaaaaaaaaa", createdAt: now)
        let store = SavedInbox.store([submission], now: { now })
        now = Date(timeIntervalSince1970: 1_700_000_600)
        let decided = try store.decide(id: submission.id, status: .changesRequested, comment: "Tighten the hook")
        XCTAssertEqual(decided.status, .changesRequested)
        XCTAssertEqual(decided.decidedAt, now)
        XCTAssertEqual(decided.comment, "Tighten the hook")
        XCTAssertTrue(store.pending.isEmpty)

        let reloaded = InboxStore(file: store.file, now: { now })
        XCTAssertEqual(reloaded.all(since: nil).first?.status, .changesRequested)
        XCTAssertEqual(reloaded.all(since: nil).first?.decidedAt, now)
    }

    func testDecideTwiceThrowsAndUnknownIDThrows() throws {
        let submission = SavedInbox.post("sub_aaaaaaaaaaaa")
        let store = SavedInbox.store([submission])
        _ = try store.decide(id: submission.id, status: .approved, comment: nil)
        // Typed so the router can pick 409 vs 404 without reading the copy; the sentences are what the app shows.
        let twice = XCTAssertThrowsErrorReturning { try store.decide(id: submission.id, status: .denied, comment: nil) }
        XCTAssertEqual(twice as? InboxError, .alreadyDecided)
        XCTAssertEqual(twice.localizedDescription, "Already decided.")
        let missing = XCTAssertThrowsErrorReturning { try store.decide(id: "sub_000000000000", status: .denied, comment: nil) }
        XCTAssertEqual(missing as? InboxError, .notFound)
        XCTAssertEqual(missing.localizedDescription, "Not found.")
    }

    /// A decision that could not be written must not linger in memory: the app would be told the save failed
    /// while this process went on answering "approved" for it, and the next restart — reading the file — would
    /// disagree with everything the running helper had said.
    func testADecisionThatCannotBeSavedLeavesMemoryAsItWas() throws {
        let directory = makeDirectory()
        let submission = SavedInbox.post("sub_aaaaaaaaaaaa")
        let store = SavedInbox.store([submission], file: directory.appendingPathComponent("inbox.json"))
        // Nothing can be written from here on: the folder the file lives in is gone.
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try store.decide(id: submission.id, status: .approved, comment: "Looks good"))
        let waiting = store.pending
        XCTAssertEqual(waiting.map(\.id), [submission.id], "it is still pending")
        XCTAssertEqual(waiting.first?.status, .pending)
        XCTAssertNil(waiting.first?.comment)
        XCTAssertNil(waiting.first?.decidedAt)
    }

    // MARK: all(since:)

    func testAllSinceFiltersAndSortsNewestFirst() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = SavedInbox.post("sub_aaaaaaaaaaaa", title: "Old", createdAt: now)
        let recent = SavedInbox.post("sub_bbbbbbbbbbbb", title: "Recent", createdAt: now.addingTimeInterval(60 * 24 * 3600))
        let stillPending = SavedInbox.post("sub_cccccccccccc", title: "Pending", createdAt: now.addingTimeInterval(60 * 24 * 3600 + 60))
        let store = SavedInbox.store([old, recent, stillPending], now: { now })
        _ = try store.decide(id: old.id, status: .approved, comment: nil)
        now = now.addingTimeInterval(60 * 24 * 3600 + 60)   // 60 days later
        _ = try store.decide(id: recent.id, status: .denied, comment: nil)

        let defaultWindow = store.all(since: nil)
        XCTAssertEqual(defaultWindow.map(\.id), [stillPending.id, recent.id])   // newest first, the old decision aged out

        let sinceFuture = store.all(since: now.addingTimeInterval(3600))
        XCTAssertEqual(sinceFuture.map(\.id), [stillPending.id])   // only pending survives a future cutoff

        let sinceStart = store.all(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(sinceStart.count, 3)
    }

    // MARK: prune

    func testPruneDecidedRemovesOldDecisionsOnly() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = SavedInbox.post("sub_aaaaaaaaaaaa", title: "Old", createdAt: now)
        let keptPending = SavedInbox.post("sub_bbbbbbbbbbbb", title: "Pending", createdAt: now)
        let fresh = SavedInbox.post("sub_cccccccccccc", title: "Fresh", createdAt: now.addingTimeInterval(40 * 24 * 3600))
        let store = SavedInbox.store([old, keptPending, fresh], now: { now })
        _ = try store.decide(id: old.id, status: .approved, comment: nil)
        now = now.addingTimeInterval(40 * 24 * 3600)
        _ = try store.decide(id: fresh.id, status: .denied, comment: nil)

        let removed = try store.pruneDecided(olderThan: 30 * 24 * 3600)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(Set(store.all(since: Date(timeIntervalSince1970: 0)).map(\.id)), [keptPending.id, fresh.id])
        let reloaded = InboxStore(file: store.file, now: { now })
        XCTAssertEqual(reloaded.all(since: Date(timeIntervalSince1970: 0)).count, 2)
        XCTAssertEqual(try store.pruneDecided(olderThan: 30 * 24 * 3600), 0)
    }

    // MARK: context

    func testContextStoreRoundTrip() throws {
        let file = makeDirectory().appendingPathComponent("context.json")
        let store = ContextStore(file: file)
        XCTAssertNil(store.current)
        let context = WorkspaceContext(
            creatorName: "Chey",
            pillars: [ContextPillar(name: "Health", detail: "Body and mind", isAnchor: true, weekdays: [1, 3, 5])],
            platforms: [ContextPlatform(name: "TikTok", formats: ["Reel", "Carousel"], weeklyGoal: 4)],
            series: [ContextSeries(name: "Five mornings", pillar: "Health",
                                   episodes: [ContextEpisode(number: 1, date: "2026-09-20", title: "Wake", filled: true)])],
            creatorContext: "Writes short",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(context)
        XCTAssertEqual(store.current, context)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(ContextStore(file: file).current, context)

        var updated = context
        updated.creatorName = "Cheyenne"
        try store.save(updated)
        XCTAssertEqual(ContextStore(file: file).current?.creatorName, "Cheyenne")
    }

    // MARK: JSON shape

    func testJSONUsesISO8601DatesAndCamelCaseKeys() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var submission = SavedInbox.post("sub_aaaaaaaaaaaa", createdAt: now)
        submission.post?.postingDate = "2026-09-20"
        submission.post?.scenes = [SubmittedScene(script: "Wake up", shotNotes: "Wide")]
        let store = SavedInbox.store([submission], now: { now })
        _ = try store.decide(id: submission.id, status: .approved, comment: "Looks good")
        let raw = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""), raw)
        XCTAssertTrue(raw.contains("\"decidedAt\""))
        XCTAssertTrue(raw.contains("\"shotNotes\""))
        XCTAssertTrue(raw.contains("\"postingDate\""))
        XCTAssertTrue(raw.contains("\"status\" : \"approved\""))
        XCTAssertFalse(raw.contains("_at"))
        XCTAssertFalse(raw.contains("posting_date"))

        let contextFile = makeDirectory().appendingPathComponent("context.json")
        let contextStore = ContextStore(file: contextFile)
        try contextStore.save(WorkspaceContext(creatorName: "Chey", pillars: [ContextPillar(name: "Health", detail: "", isAnchor: false, weekdays: [])],
                                               platforms: [], series: [], creatorContext: nil, updatedAt: now))
        let contextRaw = try String(contentsOf: contextFile, encoding: .utf8)
        XCTAssertTrue(contextRaw.contains("\"updatedAt\" : \"2023-11-14T22:13:20Z\""), contextRaw)
        XCTAssertTrue(contextRaw.contains("\"isAnchor\""))
    }

    // MARK: paths

    func testBridgePathsExposeInboxAndContext() {
        let paths = BridgePaths(root: URL(fileURLWithPath: "/tmp/root"), logs: URL(fileURLWithPath: "/tmp/logs"))
        XCTAssertEqual(paths.inbox.lastPathComponent, "inbox.json")
        XCTAssertEqual(paths.context.lastPathComponent, "context.json")
        XCTAssertEqual(paths.inbox.deletingLastPathComponent().path, "/tmp/root")
        XCTAssertEqual(paths.context.deletingLastPathComponent().path, "/tmp/root")
    }

    /// The Inbox needs 0.2.0 or newer; pinning the exact version here broke on the very next release.
    func testVersionSupportsTheInbox() {
        XCTAssertEqual(BridgeVersion.current.compare("0.2.0", options: .numeric) == .orderedAscending, false)
        XCTAssertEqual(BridgeVersion.protocolVersion, 2)
    }
}

/// Runs `body`, returning the error it threw (or a placeholder when it did not throw).
private func XCTAssertThrowsErrorReturning(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> Error {
    do {
        try body()
        XCTFail("Expected an error", file: file, line: line)
        return BridgeError.message("no error thrown")
    } catch {
        return error
    }
}

/// What `iris-bridge inbox` prints for a submission: one clean line with its age.
final class SubmissionListingTests: XCTestCase {
    func testALongTitleIsCutToEightyCharactersWithAnEllipsis() {
        let submission = Submission(id: "sub_aaaaaaaaaaaa", kind: .post,
                                    post: SubmittedPost(title: String(repeating: "a", count: 200),
                                                        pillar: "Craft", platform: "Instagram", format: "Reel"),
                                    agent: "claude", createdAt: Date())
        XCTAssertEqual(submission.listTitle.count, 80)
        XCTAssertTrue(submission.listTitle.hasSuffix("…"), submission.listTitle)
    }

    func testAShortPlainTitleIsLeftExactlyAsItIs() {
        XCTAssertEqual(OneLineText.clean("Three shots", limit: 80), "Three shots")
        XCTAssertEqual(OneLineText.clean("  spaced out  ", limit: 80), "spaced out")
        XCTAssertEqual(OneLineText.clean("\u{1B}]0;title\u{07}after", limit: 80), "after")
        XCTAssertEqual(OneLineText.clean(String(repeating: "b", count: 80), limit: 80).count, 80)
    }

    func testSubmissionAgeReadsAsMinutesHoursOrDays() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        func age(_ seconds: TimeInterval) -> String {
            Submission(id: "sub_aaaaaaaaaaaa", kind: .post, agent: "claude",
                       createdAt: now.addingTimeInterval(-seconds)).ageText(now: now)
        }
        XCTAssertEqual(age(30), "0m")
        XCTAssertEqual(age(3 * 60), "3m")
        XCTAssertEqual(age(2 * 60 * 60), "2h")
        XCTAssertEqual(age(26 * 60 * 60), "1d")
    }

    func testSubmissionTitleFallsBackToTheSeriesNameThenToTheKind() {
        XCTAssertEqual(Submission(id: "sub_aaaaaaaaaaaa", kind: .post,
                                  post: SubmittedPost(title: "Three shots", pillar: "Craft", platform: "Instagram", format: "Reel"),
                                  agent: "claude", createdAt: Date()).displayTitle, "Three shots")
        XCTAssertEqual(Submission(id: "sub_aaaaaaaaaaaa", kind: .series,
                                  series: SubmittedSeries(name: "Quiet mornings", pillar: "Craft", episodes: []),
                                  agent: "claude", createdAt: Date()).displayTitle, "Quiet mornings")
        XCTAssertEqual(Submission(id: "sub_aaaaaaaaaaaa", kind: .post, agent: "claude", createdAt: Date()).displayTitle, "Untitled post")
    }
}
