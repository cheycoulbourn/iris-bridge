import XCTest
@testable import IrisBridgeCore

final class SubmissionsTests: XCTestCase {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func makeStore(now: @escaping () -> Date = Date.init) -> InboxStore {
        InboxStore(file: makeDirectory().appendingPathComponent("inbox.json"), now: now)
    }
    private func samplePost(title: String = "Morning routine", pillar: String = "Health", platform: String = "TikTok") -> SubmittedPost {
        SubmittedPost(title: title, pillar: pillar, platform: platform, format: "Reel", postingDate: "2026-09-20",
                      hook: "Try this before coffee", script: "Do the thing.", scenes: [SubmittedScene(script: "Wake up", shotNotes: "Wide")],
                      caption: "A caption", cta: "Follow", notes: nil, seriesName: nil, episode: nil)
    }
    private func sampleSeries(episodes: Int = 3) -> SubmittedSeries {
        SubmittedSeries(name: "Five mornings", pillar: "Health", summary: "A short run",
                        episodes: (1...episodes).map { SubmittedEpisode(number: $0, date: nil, post: samplePost(title: "Episode \($0)")) })
    }
    private func message(_ error: Error) -> String? {
        guard case .message(let text)? = error as? BridgeError else { return nil }
        return text
    }

    // MARK: submit

    func testSubmitReturnsPendingWithIDAndPersists() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { now })
        let submission = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: "Take a look", revisionOf: nil)
        XCTAssertTrue(submission.id.hasPrefix("sub_"))
        XCTAssertEqual(submission.id.count, 16)
        XCTAssertTrue(submission.id.dropFirst(4).allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber })
        XCTAssertEqual(submission.status, .pending)
        XCTAssertEqual(submission.createdAt, now)
        XCTAssertNil(submission.decidedAt)
        XCTAssertEqual(submission.agent, "claude")
        XCTAssertEqual(submission.note, "Take a look")
        XCTAssertEqual(submission.post, samplePost())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let reloaded = InboxStore(file: store.file, now: { now })
        XCTAssertEqual(reloaded.pending.map(\.id), [submission.id])
        XCTAssertEqual(reloaded.pending.first?.post, samplePost())
    }

    func testMakeIDIsUniqueAndLowercaseAlphanumeric() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let id = InboxStore.makeID()
            XCTAssertEqual(id.count, 16)
            XCTAssertTrue(id.hasPrefix("sub_"))
            let body = id.dropFirst(4)
            XCTAssertTrue(body.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
            XCTAssertTrue(seen.insert(id).inserted)
        }
    }

    func testSubmitSeriesKeepsEpisodes() throws {
        let store = makeStore()
        let submission = try store.submit(kind: .series, post: nil, series: sampleSeries(), agent: "codex", note: nil, revisionOf: nil)
        XCTAssertEqual(submission.kind, .series)
        XCTAssertEqual(submission.series?.episodes.count, 3)
        XCTAssertNil(submission.post)
    }

    func testRevisionOfIsStored() throws {
        let store = makeStore()
        let first = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: nil)
        let second = try store.submit(kind: .post, post: samplePost(title: "Better"), series: nil, agent: "claude", note: nil, revisionOf: first.id)
        XCTAssertEqual(second.revisionOf, first.id)
        XCTAssertNotEqual(second.id, first.id)
    }

    func testLongNoteIsClampedToTwoThousandCharacters() throws {
        let store = makeStore()
        let note = String(repeating: "a", count: 10_000)
        let submission = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: note, revisionOf: nil)
        XCTAssertEqual(submission.note?.count, 2_000)
        XCTAssertEqual(submission.note, String(repeating: "a", count: 2_000))

        let reloaded = InboxStore(file: store.file)
        XCTAssertEqual(reloaded.pending.first?.note?.count, 2_000)
    }

    func testNoteIsTrimmedAndBlankNoteBecomesNil() throws {
        let store = makeStore()
        let kept = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: "  Take a look\n", revisionOf: nil)
        XCTAssertEqual(kept.note, "Take a look")
        let blank = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: "   \n ", revisionOf: nil)
        XCTAssertNil(blank.note)
    }

    func testInvalidRevisionOfIsRefused() throws {
        let store = makeStore()
        for bad in ["nope", "sub_SHOUTING123", "sub_abc", "sub_abcdef1234567", "abcdefghijkl", "sub_abcdef 12345", ""] {
            let error = XCTAssertThrowsErrorReturning {
                _ = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: bad)
            }
            XCTAssertEqual(message(error), "That submission id is not valid.", "revisionOf: \(bad)")
        }
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testValidRevisionOfIsKept() throws {
        let store = makeStore()
        let submission = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: "sub_abcdef123456")
        XCTAssertEqual(submission.revisionOf, "sub_abcdef123456")

        let reloaded = InboxStore(file: store.file)
        XCTAssertEqual(reloaded.pending.first?.revisionOf, "sub_abcdef123456")
    }

    // MARK: validation

    func testValidationRejectsMissingPayload() {
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .post, post: nil, series: nil) }), "Add a post to submit.")
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .series, post: nil, series: nil) }), "Add a series to submit.")
    }

    func testValidationRejectsEmptyTitlePillarPlatform() {
        var post = samplePost(title: "   ")
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .post, post: post, series: nil) }), "Give the post a title.")
        post = samplePost(pillar: "")
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .post, post: post, series: nil) }), "Choose a pillar.")
        post = samplePost(platform: "")
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .post, post: post, series: nil) }), "Choose a platform.")
    }

    func testValidationRejectsTooManyScenes() {
        var post = samplePost()
        post.scenes = (0..<41).map { SubmittedScene(script: "Scene \($0)", shotNotes: "") }
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .post, post: post, series: nil) }), "Choose up to 40 scenes.")
        post.scenes = (0..<40).map { SubmittedScene(script: "Scene \($0)", shotNotes: "") }
        XCTAssertNoThrow(try SubmissionValidation.validate(kind: .post, post: post, series: nil))
    }

    func testValidationRejectsTooManyEpisodes() {
        let tooMany = SubmittedSeries(name: "Long run", pillar: "Health", summary: nil,
                                      episodes: (1...53).map { SubmittedEpisode(number: $0, date: nil, post: samplePost(title: "E\($0)")) })
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .series, post: nil, series: tooMany) }),
                       "A series can have up to 52 episodes.")
        let empty = SubmittedSeries(name: "Empty", pillar: "Health", summary: nil, episodes: [])
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .series, post: nil, series: empty) }),
                       "Add at least one episode.")
    }

    func testValidationRejectsTooMuchText() {
        var post = samplePost()
        post.script = String(repeating: "a", count: 24_001)
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .post, post: post, series: nil) }),
                       "This submission is too long. Keep it under 24,000 characters.")
        var series = sampleSeries(episodes: 2)
        series.episodes[0].post.caption = String(repeating: "b", count: 24_001)
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .series, post: nil, series: series) }),
                       "This submission is too long. Keep it under 24,000 characters.")
    }

    func testValidationRejectsEmptySeriesName() {
        let series = SubmittedSeries(name: " ", pillar: "Health", summary: nil, episodes: [SubmittedEpisode(number: 1, date: nil, post: samplePost())])
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try SubmissionValidation.validate(kind: .series, post: nil, series: series) }),
                       "Give the series a name.")
    }

    func testSubmitValidates() {
        let store = makeStore()
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try store.submit(kind: .post, post: samplePost(title: ""), series: nil, agent: "claude", note: nil, revisionOf: nil) }),
                       "Give the post a title.")
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testPendingLimitRefusesTwoHundredAndFirst() throws {
        let store = makeStore()
        for index in 0..<200 {
            _ = try store.submit(kind: .post, post: samplePost(title: "Post \(index)"), series: nil, agent: "claude", note: nil, revisionOf: nil)
        }
        XCTAssertEqual(store.pending.count, 200)
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: nil) }),
                       "Iris has 200 submissions waiting. Ask the creator to clear the Inbox first.")
        _ = try store.decide(id: store.pending[0].id, status: .approved, comment: nil)
        XCTAssertNoThrow(try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: nil))
    }

    // MARK: decide

    func testDecideFlipsStatusAndSetsDecidedAt() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { now })
        let submission = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: nil)
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
        let store = makeStore()
        let submission = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: nil)
        _ = try store.decide(id: submission.id, status: .approved, comment: nil)
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try store.decide(id: submission.id, status: .denied, comment: nil) }), "Already decided.")
        XCTAssertEqual(message(XCTAssertThrowsErrorReturning { try store.decide(id: "sub_000000000000", status: .denied, comment: nil) }), "Not found.")
    }

    // MARK: all(since:)

    func testAllSinceFiltersAndSortsNewestFirst() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { now })
        let old = try store.submit(kind: .post, post: samplePost(title: "Old"), series: nil, agent: "claude", note: nil, revisionOf: nil)
        _ = try store.decide(id: old.id, status: .approved, comment: nil)
        now = now.addingTimeInterval(60 * 24 * 3600)   // 60 days later
        let recent = try store.submit(kind: .post, post: samplePost(title: "Recent"), series: nil, agent: "claude", note: nil, revisionOf: nil)
        now = now.addingTimeInterval(60)
        let stillPending = try store.submit(kind: .post, post: samplePost(title: "Pending"), series: nil, agent: "claude", note: nil, revisionOf: nil)
        _ = try store.decide(id: recent.id, status: .denied, comment: nil)

        let defaultWindow = store.all(since: nil)
        XCTAssertEqual(Set(defaultWindow.map(\.id)), [recent.id, stillPending.id])
        XCTAssertEqual(defaultWindow.map(\.id), [stillPending.id, recent.id])   // newest first

        let sinceFuture = store.all(since: now.addingTimeInterval(3600))
        XCTAssertEqual(sinceFuture.map(\.id), [stillPending.id])   // only pending survives a future cutoff

        let sinceStart = store.all(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(sinceStart.count, 3)
    }

    // MARK: prune

    func testPruneDecidedRemovesOldDecisionsOnly() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { now })
        let old = try store.submit(kind: .post, post: samplePost(title: "Old"), series: nil, agent: "claude", note: nil, revisionOf: nil)
        _ = try store.decide(id: old.id, status: .approved, comment: nil)
        let keptPending = try store.submit(kind: .post, post: samplePost(title: "Pending"), series: nil, agent: "claude", note: nil, revisionOf: nil)
        now = now.addingTimeInterval(40 * 24 * 3600)
        let fresh = try store.submit(kind: .post, post: samplePost(title: "Fresh"), series: nil, agent: "claude", note: nil, revisionOf: nil)
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
        let store = makeStore(now: { now })
        let submission = try store.submit(kind: .post, post: samplePost(), series: nil, agent: "claude", note: nil, revisionOf: nil)
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

    func testVersionIsZeroTwoZero() {
        XCTAssertEqual(BridgeVersion.current, "0.2.0")
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
