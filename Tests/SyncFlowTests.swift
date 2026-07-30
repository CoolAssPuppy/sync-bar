//
//  SyncFlowTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The redesign's atomic object: a Sync = (rule, binding). These pin the
//  per-sync override resolution and the row summary, which the new UI relies on.
//

import XCTest
@testable import SyncBar

final class SyncFlowTests: XCTestCase {

    private func markdownBinding(tags: [String]? = nil) -> DestinationBinding {
        DestinationBinding(
            configuration: .markdownFolder(MarkdownFolderDestinationConfig(
                folderPath: "/tmp/notes", fileNameTemplate: "{title}", includeFrontmatter: true)),
            requiredTags: tags
        )
    }

    func test_binding_overrides_win_over_rule_defaults() {
        var rule = SyncRule.new(notebookId: "f1", notebookName: "Work")
        rule.updateRemarkable { $0.titleStrategy = .fileName; $0.ocrMode = .none }
        var binding = markdownBinding(tags: ["idea"])
        binding.titleStrategyOverride = .firstLineOfOcr
        binding.ocrModeOverride = .all

        let flow = SyncFlow(rule: rule, binding: binding)

        // A per-sync override beats the folder-level rule default.
        XCTAssertEqual(flow.titleStrategy, .firstLineOfOcr)
        XCTAssertEqual(flow.ocrMode, .all)
        XCTAssertEqual(flow.requiredTags, ["idea"])
    }

    func test_falls_back_to_rule_when_no_override() {
        var rule = SyncRule.new(notebookId: "f1", notebookName: "Work")
        rule.updateRemarkable { $0.titleStrategy = .template; $0.ocrMode = .handwrittenOnly }
        let flow = SyncFlow(rule: rule, binding: markdownBinding())

        XCTAssertEqual(flow.titleStrategy, .template)
        XCTAssertEqual(flow.ocrMode, .handwrittenOnly)
        XCTAssertTrue(flow.requiredTags.isEmpty)
    }

    func test_how_summary_describes_the_sync() {
        var rule = SyncRule.new(notebookId: "f1", notebookName: "Work")
        var binding = markdownBinding(tags: ["work"])
        binding.titleStrategyOverride = .firstLineOfOcr
        binding.ocrModeOverride = .all

        let summary = SyncFlow(rule: rule, binding: binding).howSummary
        XCTAssertTrue(summary.contains("First line"))
        XCTAssertTrue(summary.contains("OCR all pages"))
        XCTAssertTrue(summary.contains("work"))
    }

    /// OCR and title strategy belong to handwriting. A Notion page arrives with a
    /// title and nothing to recognize, so its row says what it moves instead.
    func test_how_summary_of_a_notion_sync_names_the_flow_not_ocr() {
        let source = NotionSourceConfig(
            workspaceId: "ws-1", workspaceName: "Workspace", databaseId: "db-1",
            databaseTitle: "Notes", titleProperty: "Title")
        let rule = SyncRule(source: .notion(source))

        let summary = SyncFlow(rule: rule, binding: markdownBinding()).howSummary

        XCTAssertTrue(summary.contains("Notes"), summary)
        XCTAssertFalse(summary.contains("OCR"), summary)
        XCTAssertFalse(summary.contains("as title"), summary)
    }

    func test_disabled_binding_is_not_enabled() {
        let rule = SyncRule.new(notebookId: "f1", notebookName: "Work")
        var binding = markdownBinding()
        binding.enabled = false
        XCTAssertFalse(SyncFlow(rule: rule, binding: binding).isEnabled)
    }
}
