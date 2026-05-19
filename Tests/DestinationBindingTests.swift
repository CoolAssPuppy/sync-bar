//
//  DestinationBindingTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

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
