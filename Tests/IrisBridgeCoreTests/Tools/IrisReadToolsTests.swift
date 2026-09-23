import XCTest
@testable import IrisBridgeCore

final class IrisReadToolsTests: XCTestCase {
    private var store: SnapshotStore!
    private var tools: IrisReadTools!
    private var paired = true
    /// Two minutes after the fixture was received: 2026-10-05 10:02 in New York.
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T14:02:00Z")!

    override func setUp() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let received = ISO8601DateFormatter().date(from: "2026-10-05T14:00:00Z")!
        store = SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: ContextStore(file: folder.appendingPathComponent("context.json")),
                              now: { received })
        tools = IrisReadTools(snapshots: store, hasPairedDevices: { [unowned self] in self.paired }, now: { [unowned self] in self.now })
    }

    private func push() { XCTAssertNil(store.push(profileId: SnapshotFixture.profile, revision: "rev-1", snapshot: SnapshotFixture.json)) }

    private func call(_ name: String, _ arguments: JSONValue = [:], file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        guard let result = tools.call(name, arguments.objectValue ?? [:]) else { XCTFail("\(name) is not a read tool", file: file, line: line); return .null }
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return (try? JSONValue.decode(Data(result.text.utf8))) ?? .null
    }

    func testWithoutASnapshotTheAgentIsToldWhatToDo() {
        XCTAssertEqual(tools.call("iris_workspace_summary", [:]), .failure(IrisReadTools.noSnapshot))
        paired = false
        XCTAssertEqual(tools.call("iris_workspace_summary", [:]), .failure(Router.notPairedSentence))
        push()
        XCTAssertEqual(tools.call("iris_list_posts", ["profileID": "A1B2C3D4-0000-4000-8000-000000000009"]), .failure(IrisReadTools.noProfile))
        XCTAssertNil(tools.call("iris_create_task", [:]), "change tools are not answered here")
    }

    func testTheSummaryNamesTodayOnTheCreatorsClockAndHowOldTheSnapshotIs() {
        push()
        let summary = call("iris_workspace_summary")
        XCTAssertEqual(summary["today"], "2026-10-05")
        XCTAssertEqual(summary["timeZone"], "America/New_York")
        XCTAssertEqual(summary["creator"], "Robin Vale")
        XCTAssertEqual(summary["creatorNotes"], "Speaks plainly. No exclamation marks.")
        XCTAssertEqual(summary["counts"]?["openTasks"]?.intValue, 2)
        XCTAssertEqual(summary["counts"]?["postsByStage"]?["editing"]?.intValue, 1)
        XCTAssertNil(summary["counts"]?["postsByStage"]?["published"], "archived posts are not counted")
        XCTAssertEqual(summary["asOf"]?["minutesOld"]?.intValue, 2)
        XCTAssertEqual(summary["asOf"]?["revision"], "rev-1")
        XCTAssertEqual(summary["pillars"]?.arrayValue?.first?["usualDays"], ["Mon", "Wed", "Fri"])
    }

    func testPostsFilterByDateStagePillarTextAndPage() {
        push()
        XCTAssertEqual(call("iris_list_posts")["total"]?.intValue, 4, "archived posts are left out by default")
        XCTAssertEqual(call("iris_list_posts", ["includeArchived": true])["total"]?.intValue, 5)
        let week = call("iris_list_posts", ["from": "2026-10-05", "to": "2026-10-11"])
        XCTAssertEqual(week["posts"]?.arrayValue?.map { $0["date"] }, ["2026-10-08", "2026-10-07", "2026-10-06"])
        XCTAssertEqual(call("iris_list_posts", ["stage": "editing"])["posts"]?.arrayValue?.first?["title"], "Glazing day")
        XCTAssertEqual(call("iris_list_posts", ["pillar": "slow mornings"])["total"]?.intValue, 2)
        XCTAssertEqual(call("iris_list_posts", ["text": "PHONE"])["posts"]?.arrayValue?.count, 1)
        let page = call("iris_list_posts", ["limit": 3])
        XCTAssertEqual(page["nextOffset"]?.intValue, 3)
        XCTAssertEqual(call("iris_list_posts", ["offset": 3])["nextOffset"], .null)
        XCTAssertEqual(tools.call("iris_list_posts", ["from": "October 5"])?.text, "Give from as yyyy-MM-dd.")
        XCTAssertEqual(tools.call("iris_list_posts", ["limit": 500])?.isError, true)
    }

    func testOnePostInFullWithItsRevision() {
        push()
        let post = call("iris_get_post", ["postID": "c0000000-0000-4000-8000-000000000001"])["post"]
        XCTAssertEqual(post?["revision"], "r-p1")
        XCTAssertEqual(post?["hook"], "I stopped checking my phone first thing.")
        XCTAssertEqual(post?["scenes"]?.arrayValue?.first?["script"], "Kettle on.")
        XCTAssertEqual(tools.call("iris_get_post", ["postID": .string(UUID().uuidString)])?.text, "That post is not in the workspace Iris shared.")
    }

    func testTasksIdeasSeriesAndPillars() {
        push()
        XCTAssertEqual(call("iris_list_tasks")["tasks"]?.arrayValue?.map { $0["title"] }, ["Buy oat milk for the shoot", "Send the kiln invoice"])
        XCTAssertEqual(call("iris_list_tasks", ["status": "done"])["tasks"]?.arrayValue?.first?["dueTime"], "09:00")
        XCTAssertEqual(call("iris_list_tasks", ["status": "all", "from": "2026-10-07"])["tasks"]?.arrayValue?.count, 1)
        XCTAssertEqual(call("iris_list_ideas", ["pillar": "Slow mornings"])["ideas"]?.arrayValue?.count, 1)
        let series = call("iris_list_series")["series"]?.arrayValue?.first
        XCTAssertEqual(series?["episodes"]?.arrayValue?.first?["title"], "Morning light, episode 1")
        XCTAssertNil(series?["episodes"]?.arrayValue?.last?["postID"])
        XCTAssertEqual(call("iris_list_pillars")["pillars"]?.arrayValue?.count, 3)
    }

    func testTheScheduleListsEachDayWithPostsTasksAndFocus() {
        push()
        let days = call("iris_get_schedule", ["from": "2026-10-05", "to": "2026-10-07"])["days"]?.arrayValue ?? []
        XCTAssertEqual(days.map { $0["date"] }, ["2026-10-05", "2026-10-06", "2026-10-07"])
        XCTAssertEqual(days[0]["focus"], ["Film"], "Monday")
        XCTAssertEqual(days[1]["posts"]?.arrayValue?.first?["title"], "The kettle before the phone")
        XCTAssertEqual(days[1]["tasksDue"]?.arrayValue?.first?["title"], "Buy oat milk for the shoot")
        XCTAssertEqual(days[2]["focus"], [], "Tuesday has no theme")
        XCTAssertEqual(tools.call("iris_get_schedule", ["from": "2026-10-01", "to": "2026-12-31"])?.text, "Ask for 62 days or fewer at a time.")
        XCTAssertEqual(tools.call("iris_get_schedule", ["from": "2026-10-09", "to": "2026-10-01"])?.isError, true)
    }

    func testSearchDuplicatesAndTheInbox() {
        push()
        let found = call("iris_search", ["text": "kiln"])
        XCTAssertEqual(found["ideas"]?.arrayValue?.first?["title"], "Kiln cam")
        XCTAssertEqual(found["tasks"]?.arrayValue?.first?["title"], "Send the kiln invoice")
        XCTAssertEqual(found["posts"]?.arrayValue?.count, 1)
        XCTAssertNil(call("iris_search", ["text": "kiln", "kinds": ["idea"]])["posts"])
        let groups = call("iris_find_duplicate_posts")["candidates"]?.arrayValue ?? []
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["posts"]?.arrayValue?.count, 2)
        let inbox = call("iris_list_review_items")["items"]?.arrayValue ?? []
        XCTAssertEqual(inbox.map { $0["status"] }, ["pending", "changesRequested"])
        XCTAssertEqual(inbox.last?["comment"], "Make it three episodes.")
    }

    func testAnOlderAppsContextAnswersWithANote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = ContextStore(file: folder.appendingPathComponent("context.json"))
        try context.save(WorkspaceContext(creatorName: "Robin", pillars: [ContextPillar(name: "Craft", detail: "How it is made", isAnchor: true, weekdays: [2])],
                                          platforms: [ContextPlatform(name: "Instagram", formats: ["Reel", "Carousel"], weeklyGoal: 3)], series: [],
                                          creatorContext: "Speaks plainly.", updatedAt: now.addingTimeInterval(-600)))
        let legacy = IrisReadTools(snapshots: SnapshotStore(folder: folder.appendingPathComponent("snapshots"), legacy: context),
                                   hasPairedDevices: { true }, now: { self.now })
        let summary = try JSONValue.decode(Data(try XCTUnwrap(legacy.call("iris_workspace_summary", [:])).text.utf8))
        XCTAssertEqual(summary["pillars"]?.arrayValue?.first?["name"], "Craft")
        XCTAssertEqual(summary["creatorNotes"], "Speaks plainly.")
        XCTAssertEqual(summary["asOf"]?["minutesOld"]?.intValue, 10)
        XCTAssertNotNil(summary["asOf"]?["note"])
    }
}
