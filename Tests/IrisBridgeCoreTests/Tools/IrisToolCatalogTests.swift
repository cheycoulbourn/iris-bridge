import XCTest
@testable import IrisBridgeCore

final class IrisToolCatalogTests: XCTestCase {
    /// Spec §5.1 as phase 2 defined it (`IrisActionName`): every name, nothing else, and none of v0.2.x's.
    func testTheToolsAreExactlyTheVocabulary() {
        let reads = ["iris_workspace_summary", "iris_list_posts", "iris_get_post", "iris_list_tasks", "iris_list_ideas", "iris_list_series",
                     "iris_list_pillars", "iris_get_schedule", "iris_search", "iris_find_duplicate_posts", "iris_list_review_items"]
        let changes = ["iris_create_task", "iris_update_task", "iris_complete_task", "iris_create_idea", "iris_update_idea",
                       "iris_create_post_draft", "iris_update_post_draft", "iris_attach_to_post", "iris_schedule_post", "iris_set_stage",
                       "iris_mark_posted", "iris_archive", "iris_create_series", "iris_revise_review_item"]
        XCTAssertEqual(IrisToolCatalog.reads.map(\.name), reads)
        XCTAssertEqual(IrisToolCatalog.changes.map(\.name), changes)
        let listed = (IrisToolCatalog.list(includingApproval: false).arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        for gone in ["iris_get_workspace_context", "iris_submit_post", "iris_submit_series", "iris_list_submissions",
                     "iris_revise_submission", "iris_propose_archive_posts"] {
            XCTAssertFalse(listed.contains(gone), gone)
        }
        XCTAssertFalse(listed.contains("approval"))
        XCTAssertTrue((IrisToolCatalog.list(includingApproval: true).arrayValue ?? []).contains { $0["name"] == "approval" })
    }

    func testEverySchemaTakesAProfileAndReadsSayTheyAreReadOnly() {
        for tool in IrisToolCatalog.all {
            let definition = tool.definition
            XCTAssertNotNil(definition["inputSchema"]?["properties"]?["profileID"], tool.name)
            for key in definition["inputSchema"]?["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(definition["inputSchema"]?["properties"]?[key.stringValue ?? ""], "\(tool.name) requires \(key) but does not describe it")
            }
            XCTAssertEqual(definition["annotations"]?["readOnlyHint"]?.boolValue, tool.kind == .read, tool.name)
            XCTAssertFalse(tool.activity.isEmpty)
        }
        let draft = IrisToolCatalog.tool(named: "iris_create_post_draft")!.definition
        XCTAssertNotNil(draft["inputSchema"]?["properties"]?["date"], "a draft with a date also asks to schedule it")
        XCTAssertNil(IrisToolCatalog.tool(named: "iris_update_post_draft")!.definition["inputSchema"]?["properties"]?["stage"], "stages move with iris_set_stage")
    }
}
