import XCTest
@testable import IrisBridgeCore

/// The pushed snapshot fixture: Fixtures/snapshot-v2.json (fictional workspace, contract §5).
enum SnapshotFixture {
    static let profile = "A1B2C3D4-0000-4000-8000-000000000001"
    static var json: JSONValue {
        let url = Bundle.module.url(forResource: "snapshot-v2", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.decode(Data(contentsOf: url))
    }
    static var snapshot: IrisSnapshot { IrisSnapshot(json: json, profileID: profile, revision: "rev-1") }
}

final class IrisSnapshotTests: XCTestCase {
    func testEveryPartOfThePushedSnapshotReads() {
        let snapshot = SnapshotFixture.snapshot
        XCTAssertEqual(snapshot.source, .stream)
        XCTAssertEqual(snapshot.timeZone.identifier, "America/New_York")
        XCTAssertEqual(snapshot.capturedAt, ISO8601DateFormatter().date(from: "2026-10-05T14:00:00Z"))
        XCTAssertEqual(snapshot.profiles.filter(\.active).map(\.name), ["Robin Vale"])
        XCTAssertEqual(snapshot.pillars.first?.weekdays, [2, 4, 6])
        XCTAssertEqual(snapshot.platforms.map(\.weeklyGoal), [3, 2])
        XCTAssertEqual(snapshot.posts.count, 5)
        XCTAssertEqual(snapshot.posts[1].time, "18:30")
        XCTAssertEqual(snapshot.posts[3].episode, 1)
        XCTAssertEqual(snapshot.posts[0].scenes.first?.shotNotes, "Top-down, steam.")
        XCTAssertEqual(snapshot.tasks.first?.subtasks.first?.done, true)
        XCTAssertNil(snapshot.tasks[2].dueDate)
        XCTAssertEqual(snapshot.ideas.last?.pillar, nil)
        XCTAssertEqual(snapshot.series.first?.episodes.map(\.number), [1, 2, 3])
        XCTAssertEqual(snapshot.focusThemes.map(\.title), ["Film", "Admin"])
        XCTAssertEqual(snapshot.reviewItems.last?.comment, "Make it three episodes.")
    }

    func testMissingAndMistypedFieldsTakeDefaults() {
        let snapshot = IrisSnapshot(json: ["schemaVersion": 2, "posts": [["title": 7, "archived": "yes", "episode": "2"]], "pillars": "none"],
                                    profileID: "p", revision: "r")
        XCTAssertEqual(snapshot.posts.first?.title, "")
        XCTAssertEqual(snapshot.posts.first?.archived, false)
        XCTAssertNil(snapshot.posts.first?.episode)
        XCTAssertEqual(snapshot.pillars, [])
        XCTAssertEqual(snapshot.timeZone, .current)
    }

    /// An app older than the v3 chat pushes only the v2 context; its planner posts become snapshot posts.
    func testAnOlderAppsContextReadsAsALegacySnapshot() throws {
        let account = UUID(uuidString: SnapshotFixture.profile)!
        let posted = PlannerPost(id: UUID(), revision: "r1", title: "Old market walk", platform: "Instagram", format: "Reel", archived: false,
                                 details: ["date": 812_000_000, "status": "Posted", "pillar": "Field trips", "episode": "2",
                                           "scenes": [["id": "S1", "text": "Walk in.", "shotNotes": "Wide"]], "ending": "Come along"])
        let drafted = PlannerPost(id: UUID(), revision: "r2", title: "Glazing day", platform: "TikTok", format: "Video", archived: false,
                                  details: ["date": 812_100_000, "workflow": ["stage": "editing"], "includesTime": true])
        let context = WorkspaceContext(creatorName: "Robin", pillars: [ContextPillar(name: "Field trips", detail: "", isAnchor: true, weekdays: [7])],
                                       platforms: [ContextPlatform(name: "Instagram", formats: ["Reel"], weeklyGoal: 3)],
                                       series: [ContextSeries(name: "Morning light", pillar: "Slow mornings", episodes: [ContextEpisode(number: 1, date: "2026-10-08", filled: true)])],
                                       creatorContext: "Plain.", updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                       planner: PlannerSnapshot(accountID: account, revision: "plan-7", capturedAt: Date(timeIntervalSince1970: 1_790_000_100), posts: [posted, drafted]))
        let snapshot = IrisSnapshot(legacy: context, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(snapshot.source, .legacy)
        XCTAssertEqual(snapshot.profileID, SnapshotFixture.profile)
        XCTAssertEqual(snapshot.revision, "plan-7")
        XCTAssertEqual(snapshot.posts.map(\.stage), ["published", "editing"])
        XCTAssertEqual(snapshot.posts[0].date, "2026-09-25")
        XCTAssertNil(snapshot.posts[0].time)
        XCTAssertEqual(snapshot.posts[1].time, "07:20")
        XCTAssertEqual(snapshot.posts[0].episode, 2)
        XCTAssertEqual(snapshot.posts[0].scenes.first?.script, "Walk in.")
        XCTAssertEqual(snapshot.posts[0].cta, "Come along")
        XCTAssertEqual(snapshot.series.first?.episodes.first?.date, "2026-10-08")
        XCTAssertEqual(snapshot.tasks, [])
    }
}

final class SnapshotStoreTests: XCTestCase {
    private var folder: URL!
    private var context: ContextStore!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        context = ContextStore(file: folder.appendingPathComponent("context.json"))
    }

    func testAPushIsKeptOnDiskAndTheLatestProfileIsTheDefault() throws {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let store = SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: context, now: { clock })
        XCTAssertNil(store.snapshot(profileID: nil))
        XCTAssertNil(store.push(profileId: SnapshotFixture.profile.lowercased(), revision: "rev-1", snapshot: SnapshotFixture.json))
        clock = clock.addingTimeInterval(60)
        let other = "A1B2C3D4-0000-4000-8000-000000000002"
        XCTAssertNil(store.push(profileId: other, revision: "rev-9", snapshot: ["schemaVersion": 2, "creatorName": "Vale Studio"]))
        XCTAssertEqual(store.snapshot(profileID: nil)?.snapshot.creatorName, "Vale Studio")
        let reopened = SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: context)
        let held = try XCTUnwrap(reopened.snapshot(profileID: SnapshotFixture.profile))
        XCTAssertEqual(held.snapshot.revision, "rev-1")
        XCTAssertEqual(held.snapshot.posts.count, 5)
        XCTAssertEqual(held.receivedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(reopened.snapshot(profileID: nil)?.snapshot.profileID, other)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("snapshots/\(other).json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testAPushIsRefusedForABadIdAnUnknownSchemaOrTooMuch() {
        let store = SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: context)
        XCTAssertEqual(store.push(profileId: "../x", revision: "r", snapshot: ["schemaVersion": 2]), "That profile id is not valid.")
        XCTAssertEqual(store.push(profileId: SnapshotFixture.profile, revision: "r", snapshot: ["schemaVersion": 3]),
                       "That snapshot uses a schema this Iris Bridge does not read. Update Iris Bridge.")
        let huge = JSONValue.object(["schemaVersion": 2, "creatorContext": .string(String(repeating: "a", count: SnapshotStore.maximumBytes))])
        XCTAssertEqual(store.push(profileId: SnapshotFixture.profile, revision: "r", snapshot: huge), "That workspace snapshot is too large.")
    }

    func testTheV2ContextIsReadOnlyUntilAV3SnapshotArrives() throws {
        try context.save(WorkspaceContext(creatorName: "Older app", pillars: [], platforms: [], series: [], updatedAt: Date(timeIntervalSince1970: 1_789_000_000)))
        let store = SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: context)
        XCTAssertEqual(store.snapshot(profileID: nil)?.snapshot.source, .legacy)
        XCTAssertEqual(store.snapshot(profileID: nil)?.receivedAt, Date(timeIntervalSince1970: 1_789_000_000))
        XCTAssertNil(store.push(profileId: SnapshotFixture.profile, revision: "rev-1", snapshot: SnapshotFixture.json))
        XCTAssertEqual(store.snapshot(profileID: nil)?.snapshot.source, .stream)
    }
}
