import XCTest
@testable import IrisBridgeCore

final class EventLogTests: XCTestCase {
    private let thread = "8b2f4c1e-7a0d-4e55-9c3b-2f1d0e6a9b77"
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func delta(_ text: String) -> [String: JSONValue] {
        ["type": "text.delta", "threadId": .string(thread), "turnId": "t1", "text": .string(text)]
    }

    func testSeqCountsUpPerThreadAndSurvivesARestart() {
        let log = EventLog(folder: folder)
        XCTAssertEqual(log.append(threadId: thread, delta("a"))?["seq"]?.intValue, 1)
        XCTAssertEqual(log.append(threadId: thread, delta("b"))?["seq"]?.intValue, 2)
        let other = UUID().uuidString
        XCTAssertEqual(log.append(threadId: other, delta("x"))?["seq"]?.intValue, 1)
        let reopened = EventLog(folder: folder)
        XCTAssertEqual(reopened.append(threadId: thread, delta("c"))?["seq"]?.intValue, 3)
        XCTAssertEqual(reopened.replay(threadId: thread, after: 1).map { $0["text"] }, ["b", "c"])
        XCTAssertEqual(reopened.replay(threadId: thread.uppercased(), after: 0).count, 3, "one log per thread whatever the id's case")
        XCTAssertEqual(reopened.replay(threadId: thread, after: 1).first?["threadId"]?.stringValue, thread, "messages keep the app's own spelling")
    }

    func testOnlyTheNewest2000AreKept() {
        let log = EventLog(folder: folder)
        for index in 1...2_300 { log.append(threadId: thread, delta("\(index)")) }
        let kept = EventLog(folder: folder).replay(threadId: thread, after: 0)
        XCTAssertLessThanOrEqual(kept.count, 2_200)
        XCTAssertGreaterThanOrEqual(kept.count, EventLog.keep)
        XCTAssertEqual(kept.last?["seq"]?.intValue, 2_300)
        XCTAssertEqual(EventLog(folder: folder).append(threadId: thread, delta("next"))?["seq"]?.intValue, 2_301)
    }

    func testATornLineIsSkippedAndABadThreadIdWritesNothing() throws {
        let log = EventLog(folder: folder)
        log.append(threadId: thread, delta("a"))
        let file = folder.appendingPathComponent(UUID(uuidString: thread)!.uuidString + ".jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"type":"text.del"#.utf8)); try handle.close()
        let reopened = EventLog(folder: folder)
        XCTAssertEqual(reopened.replay(threadId: thread, after: 0).count, 1)
        reopened.append(threadId: thread, delta("after the tear"))
        XCTAssertEqual(EventLog(folder: folder).replay(threadId: thread, after: 1).map { $0["text"] }, ["after the tear"])
        XCTAssertNil(reopened.append(threadId: "../../etc/passwd", delta("x")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
