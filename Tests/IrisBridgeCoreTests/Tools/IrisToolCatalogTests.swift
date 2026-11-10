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

    // MARK: - Sub-pillars

    private static let subpillarTools = ["iris_create_idea", "iris_update_idea", "iris_create_post_draft", "iris_update_post_draft"]

    private func properties(_ name: String) -> [String: JSONValue] {
        IrisToolCatalog.tool(named: name)!.definition["inputSchema"]?["properties"]?.objectValue ?? [:]
    }

    /// Every object key anywhere in a schema, so a nested property cannot hide.
    private func keys(in value: JSONValue) -> Set<String> {
        switch value {
        case .object(let fields): return Set(fields.keys).union(fields.values.flatMap { keys(in: $0) })
        case .array(let items): return Set(items.flatMap { keys(in: $0) })
        default: return []
        }
    }

    func testTheFourIdeaAndPostDraftToolsTakeAnOptionalSubpillarName() {
        for name in Self.subpillarTools {
            let field = properties(name)["subpillar"]
            XCTAssertEqual(field?["type"], "string", name)
            let description = field?["description"]?.stringValue ?? ""
            XCTAssertTrue(description.contains("iris_list_pillars"), name)
            XCTAssertTrue(description.contains("empty text for none"), name)
            XCTAssertTrue(description.contains("It must be under the pillar the record has once the change is made"), name)
            XCTAssertFalse(IrisToolCatalog.tool(named: name)!.required.contains("subpillar"), "\(name) must not require it")
            XCTAssertFalse((IrisToolCatalog.tool(named: name)!.definition["inputSchema"]?["required"]?.arrayValue ?? []).contains("subpillar"), name)
        }
        for name in ["iris_update_idea", "iris_update_post_draft"] {
            XCTAssertTrue(properties(name)["subpillar"]?["description"]?.stringValue?.contains("Leave it out to keep the current one.") == true, name)
        }
    }

    func testNoOtherToolTakesASubpillarAndSeriesEpisodesDoNot() {
        for tool in IrisToolCatalog.all where !Self.subpillarTools.contains(tool.name) {
            XCTAssertFalse(keys(in: tool.definition["inputSchema"] ?? .null).contains("subpillar"), "\(tool.name) must not take subpillar")
        }
        let episode = properties("iris_create_series")["episodes"]?["items"]?["properties"]?["post"]?["properties"]
        XCTAssertNotNil(episode?["title"], "the episode post schema is still there")
        XCTAssertNil(episode?["subpillar"], "the app's series schema has no subpillar key")
        for name in Self.subpillarTools {
            XCTAssertEqual(keys(in: IrisToolCatalog.tool(named: name)!.definition["inputSchema"] ?? .null).filter { $0 == "subpillar" }.count, 1, "\(name): once, at the top")
        }
    }

    func testToolDescriptionsMentionSubpillarsAndKeepTheirRules() {
        func description(_ name: String) -> String { IrisToolCatalog.tool(named: name)!.definition["description"]?.stringValue ?? "" }
        XCTAssertTrue(description("iris_update_idea").hasPrefix("Change an idea's title, note, pillar or sub-pillar."))
        XCTAssertTrue(description("iris_update_post_draft").contains("pillar, sub-pillar, platform or format"))
        XCTAssertTrue(description("iris_list_pillars").contains("usual posting weekdays and sub-pillars"))
        XCTAssertTrue(description("iris_get_post").contains("sub-pillar"))
        for name in Self.subpillarTools + ["iris_create_series"] {
            XCTAssertTrue(description(name).hasSuffix(IrisToolCatalog.rules), "\(name) keeps its rules")
        }
    }
}
