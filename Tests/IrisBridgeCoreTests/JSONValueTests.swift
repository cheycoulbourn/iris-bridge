import XCTest
@testable import IrisBridgeCore

final class JSONValueTests: XCTestCase {
    func testEveryKindRoundTripsAndKeysAreSorted() throws {
        let value: JSONValue = ["b": [1, 2.5, "x", true, nil], "a": ["nested": "yes"]]
        XCTAssertEqual(String(data: value.encoded(), encoding: .utf8), #"{"a":{"nested":"yes"},"b":[1,2.5,"x",true,null]}"#)
        XCTAssertEqual(try JSONValue.decode(value.encoded()), value)
    }

    func testAccessorsReadOnlyTheirOwnKind() {
        let value: JSONValue = ["n": 3, "f": 3.5, "s": "3", "t": true, "l": [1], "o": ["k": "v"]]
        XCTAssertEqual(value["n"]?.intValue, 3)
        XCTAssertNil(value["f"]?.intValue)
        XCTAssertNil(value["s"]?.intValue)
        XCTAssertEqual(value["s"]?.stringValue, "3")
        XCTAssertEqual(value["t"]?.boolValue, true)
        XCTAssertEqual(value["l"]?.arrayValue, [1])
        XCTAssertEqual(value["o"]?["k"]?.stringValue, "v")
        XCTAssertNil(value["missing"])
        XCTAssertNil(JSONValue.string("x")["k"])
    }

    /// The planner snapshot's `details` were `PlannerJSON` until 0.3.0: the same bytes still decode.
    func testPlannerDetailsWrittenByAnOlderHelperStillDecode() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","revision":"r1","title":"T","platform":"Instagram","format":"Reel","archived":false,"details":{"date":800000000,"scenes":[{"script":"s"}]}}"#
        let post = try JSONDecoder().decode(PlannerPost.self, from: Data(saved.utf8))
        XCTAssertEqual(post.details["date"]?.intValue, 800_000_000)
        XCTAssertEqual(post.details["scenes"]?.arrayValue?.first?["script"]?.stringValue, "s")
    }
}
