//
//  DestinationBindingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class DestinationBindingTests: XCTestCase {

    func test_codable_round_trip_for_each_kind() throws {
        let cases: [DestinationConfiguration] = [
            .notion(NotionDestinationConfig(workspaceId: "w1", destinationId: "p1", destinationType: .page, destinationTitle: "Notes")),
            .linear(LinearDestinationConfig(workspaceId: "team-1", workspaceName: "Engineering", projectId: nil, projectName: nil, defaultLabel: nil)),
            .googleDocs(GoogleDocsDestinationConfig(accountEmail: "user@example.com", folderId: nil, folderName: nil, appendMode: .onePerPage)),
            .appleNotes(AppleNotesDestinationConfig(folderName: "Travel")),
            .markdownFolder(MarkdownFolderDestinationConfig(folderPath: "/tmp/notes", fileNameTemplate: "{notebook}-{page_n}", includeFrontmatter: true))
        ]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(DestinationConfiguration.self, from: data)
            XCTAssertEqual(original, decoded, "Round-trip failed for \(original.kind.label)")
        }
    }

    func test_aggregate_status_picks_worst_outcome() {
        var rule = SyncRule.new(notebookId: "nb-1", notebookName: "Quarterly")
        rule.destinations = [
            binding(status: .success),
            binding(status: .partial),
            binding(status: .success)
        ]
        XCTAssertEqual(rule.aggregateLastRunStatus, .partial)
    }

    func test_aggregate_status_error_dominates() {
        var rule = SyncRule.new(notebookId: "nb-1", notebookName: "Quarterly")
        rule.destinations = [
            binding(status: .success),
            binding(status: .error)
        ]
        XCTAssertEqual(rule.aggregateLastRunStatus, .error)
    }

    func test_aggregate_pages_synced_sums() {
        var rule = SyncRule.new(notebookId: "nb-1", notebookName: "Quarterly")
        rule.destinations = [
            binding(status: .success, pages: 3),
            binding(status: .success, pages: 2)
        ]
        XCTAssertEqual(rule.aggregateLastRunPagesSynced, 5)
    }

    func test_rule_scope_includes_whole_folder_by_default() {
        let rule = SyncRule.new(notebookId: "nb-1", notebookName: "Personal")
        XCTAssertTrue(rule.syncsEntireFolder)
        XCTAssertTrue(rule.includes(fileId: "any-document"))
    }

    func test_rule_scoped_to_selected_notebooks_includes_only_those() {
        var rule = SyncRule.new(notebookId: "nb-1", notebookName: "Personal")
        rule.selectedFileIds = ["journal"]
        XCTAssertFalse(rule.syncsEntireFolder)
        XCTAssertTrue(rule.includes(fileId: "journal"))
        XCTAssertFalse(rule.includes(fileId: "shopping-list"))
    }

    func test_rule_persisted_without_scope_field_decodes_as_whole_folder() throws {
        // A rule saved before per-notebook scoping existed has no selectedFileIds key.
        let legacyJSON = Data("""
        {"id":"r1","enabled":true,"rmNotebookId":"nb-1","rmNotebookName":"Personal",
         "titleStrategy":"firstLineOfOcr","pageOrder":"chronological","ocrMode":"all",
         "savePdfAttachment":true,"createdAt":0,"updatedAt":0,"destinations":[]}
        """.utf8)
        let rule = try JSONDecoder().decode(SyncRule.self, from: legacyJSON)
        XCTAssertNil(rule.selectedFileIds)
        XCTAssertTrue(rule.syncsEntireFolder)
        XCTAssertTrue(rule.includes(fileId: "anything"))
    }

    func test_tag_filter_accepts_only_matching_notes_on_any_destination() {
        // The filter is per-binding now, so even a Markdown destination can use it.
        let markdown = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(folderPath: "/tmp", fileNameTemplate: "{notebook}", includeFrontmatter: false))
        let filtered = DestinationBinding(configuration: markdown, requiredTags: ["Linear", "Action"])
        XCTAssertTrue(filtered.accepts(fileTags: ["Action"]))
        XCTAssertTrue(filtered.accepts(fileTags: ["Idea", "Linear"]))
        XCTAssertFalse(filtered.accepts(fileTags: ["Idea"]))
        XCTAssertFalse(filtered.accepts(fileTags: []))
    }

    func test_unfiltered_bindings_accept_every_note() {
        let markdown = DestinationConfiguration.markdownFolder(
            MarkdownFolderDestinationConfig(folderPath: "/tmp", fileNameTemplate: "{notebook}", includeFrontmatter: false))
        let binding = DestinationBinding(configuration: markdown)
        XCTAssertTrue(binding.accepts(fileTags: []))
        XCTAssertTrue(binding.accepts(fileTags: ["anything"]))
    }

    func test_legacy_linear_config_tag_filter_still_applies() {
        // Bindings saved before the filter moved to the binding level keep working
        // via the legacy LinearDestinationConfig.requiredTags fallback.
        let legacy = DestinationBinding(configuration: .linear(LinearDestinationConfig(
            workspaceId: "t", workspaceName: "Eng", projectId: nil, projectName: nil,
            defaultLabel: nil, requiredTags: ["Action"])))
        XCTAssertNil(legacy.requiredTags)
        XCTAssertTrue(legacy.accepts(fileTags: ["Action"]))
        XCTAssertFalse(legacy.accepts(fileTags: ["Idea"]))
    }

    private func binding(status: RuleRunStatus, pages: Int = 0) -> DestinationBinding {
        DestinationBinding(
            id: UUID().uuidString,
            enabled: true,
            configuration: .markdownFolder(MarkdownFolderDestinationConfig(folderPath: "/tmp", fileNameTemplate: "{notebook}", includeFrontmatter: false)),
            createdAt: Date(),
            lastRunAt: Date(),
            lastRunStatus: status,
            lastRunPagesSynced: pages
        )
    }
}
