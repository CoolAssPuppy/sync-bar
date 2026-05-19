//
//  LedgerCascadeTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

@MainActor
final class LedgerCascadeTests: XCTestCase {

    func test_removing_markdown_target_strips_only_matching_bindings() {
        let ledger = Ledger.shared
        let suite = "LedgerCascadeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let target = MarkdownTarget(id: "md-test", displayName: "Notes",
                                    folderPath: NSTemporaryDirectory(),
                                    connectedAt: Date())
        ledger.upsertMarkdownTarget(target)

        var rule = SyncRule.new(notebookId: "nb-1", notebookName: "Quarterly")
        rule.destinations = [
            DestinationBinding(configuration: .markdownFolder(
                MarkdownFolderDestinationConfig(folderPath: target.folderPath, fileNameTemplate: "{notebook}", includeFrontmatter: false)
            )),
            DestinationBinding(configuration: .appleNotes(
                AppleNotesDestinationConfig(folderName: "Travel")
            ))
        ]
        ledger.upsertRule(rule)

        let beforeCount = ledger.rules.first(where: { $0.id == rule.id })?.destinations.count ?? 0
        XCTAssertEqual(beforeCount, 2)

        ledger.removeMarkdownTarget(id: target.id)

        let afterDestinations = ledger.rules.first(where: { $0.id == rule.id })?.destinations ?? []
        XCTAssertEqual(afterDestinations.count, 1, "Markdown binding should have been cascade-removed")
        XCTAssertEqual(afterDestinations.first?.kind, .appleNotes)

        // Cleanup so we don't pollute future test runs.
        ledger.deleteRule(id: rule.id)
    }

    func test_updateBindingRunResult_skips_unchanged_writes() {
        let ledger = Ledger.shared
        var rule = SyncRule.new(notebookId: "nb-update", notebookName: "Update test")
        let binding = DestinationBinding(
            configuration: .appleNotes(AppleNotesDestinationConfig(folderName: "Notes"))
        )
        rule.destinations = [binding]
        ledger.upsertRule(rule)

        let runAt = Date()
        ledger.updateBindingRunResult(ruleId: rule.id, bindingId: binding.id,
                                       status: .success, pagesSynced: 4, runAt: runAt)
        let firstUpdate = ledger.rules.first(where: { $0.id == rule.id })?.destinations.first?.lastRunPagesSynced
        XCTAssertEqual(firstUpdate, 4)

        // No-op call — same status, pages, runAt.
        ledger.updateBindingRunResult(ruleId: rule.id, bindingId: binding.id,
                                       status: .success, pagesSynced: 4, runAt: runAt)
        let secondUpdate = ledger.rules.first(where: { $0.id == rule.id })?.destinations.first?.lastRunPagesSynced
        XCTAssertEqual(secondUpdate, 4)

        ledger.deleteRule(id: rule.id)
    }
}
