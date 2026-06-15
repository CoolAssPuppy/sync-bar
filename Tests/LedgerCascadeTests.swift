//
//  LedgerCascadeTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

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

    func test_removing_one_of_two_markdown_targets_with_same_folder_path_does_not_strip_siblings() {
        let ledger = Ledger.shared
        let tempPath = NSTemporaryDirectory()

        let firstTarget = MarkdownTarget(id: "md-first", displayName: "Inbox",
                                         folderPath: tempPath, connectedAt: Date())
        let secondTarget = MarkdownTarget(id: "md-second", displayName: "Inbox copy",
                                          folderPath: tempPath, connectedAt: Date())
        ledger.upsertMarkdownTarget(firstTarget)
        ledger.upsertMarkdownTarget(secondTarget)

        var rule = SyncRule.new(notebookId: "nb-collision", notebookName: "Quarterly")
        rule.destinations = [
            DestinationBinding(configuration: .markdownFolder(
                MarkdownFolderDestinationConfig(folderPath: tempPath, fileNameTemplate: "{notebook}", includeFrontmatter: false)
            ))
        ]
        ledger.upsertRule(rule)

        // Removing one of two siblings that share the same folder must NOT
        // cascade — the surviving target still claims that path.
        ledger.removeMarkdownTarget(id: firstTarget.id)
        let afterDestinations = ledger.rules.first(where: { $0.id == rule.id })?.destinations ?? []
        XCTAssertEqual(afterDestinations.count, 1, "Binding should survive when a sibling target keeps the path alive")

        // Removing the last sibling DOES cascade.
        ledger.removeMarkdownTarget(id: secondTarget.id)
        let finalDestinations = ledger.rules.first(where: { $0.id == rule.id })?.destinations ?? []
        XCTAssertEqual(finalDestinations.count, 0, "Last sibling removal should clear the binding")

        ledger.deleteRule(id: rule.id)
    }

    func test_records_and_resets_external_ids_for_update_in_place() {
        let ledger = Ledger.shared
        ledger.recordSyncedPage(bindingId: "b1", pageId: "f1", versionHash: "h1", externalId: "notion-page-1")

        XCTAssertEqual(ledger.syncedHash(bindingId: "b1", pageId: "f1"), "h1")
        XCTAssertEqual(ledger.syncedExternalId(bindingId: "b1", pageId: "f1"), "notion-page-1")

        // An edit changes the hash but should keep targeting the same note.
        ledger.recordSyncedPage(bindingId: "b1", pageId: "f1", versionHash: "h2", externalId: "notion-page-1")
        XCTAssertEqual(ledger.syncedHash(bindingId: "b1", pageId: "f1"), "h2")
        XCTAssertEqual(ledger.syncedExternalId(bindingId: "b1", pageId: "f1"), "notion-page-1")

        ledger.resetSyncDatabase()
        XCTAssertNil(ledger.syncedHash(bindingId: "b1", pageId: "f1"))
        XCTAssertNil(ledger.syncedExternalId(bindingId: "b1", pageId: "f1"))
    }

    func test_demo_mode_is_isolated_and_restores_real_data() {
        let ledger = Ledger.shared
        // Seed a real rule, then verify demo mode hides it and exiting brings it back.
        var realRule = SyncRule.new(notebookId: "nb-real", notebookName: "Real Folder")
        realRule.destinations = [DestinationBinding(configuration: .appleNotes(AppleNotesDestinationConfig(folderName: "Notes")))]
        ledger.upsertRule(realRule)
        XCTAssertTrue(ledger.rules.contains { $0.id == realRule.id })

        ledger.setDemoMode(true)
        XCTAssertTrue(ledger.isDemoMode)
        XCTAssertTrue(ledger.rules.contains { $0.id == "demo-rule-1" }, "demo data should be loaded")
        XCTAssertFalse(ledger.rules.contains { $0.id == realRule.id }, "real rule must not appear in demo mode")

        ledger.setDemoMode(false)
        XCTAssertFalse(ledger.isDemoMode)
        XCTAssertFalse(ledger.rules.contains { $0.id == "demo-rule-1" }, "demo data must be gone after exit")
        XCTAssertTrue(ledger.rules.contains { $0.id == realRule.id }, "real rule must come back")

        ledger.deleteRule(id: realRule.id)
    }

    func test_disconnecting_remarkable_clears_account_folders_and_rules() {
        let ledger = Ledger.shared

        ledger.setRemarkableAccount(RemarkableAccount(pairedAt: Date(), userIdentifier: "user-1", lastSyncedAt: nil))
        ledger.setFolders([RmFolder(id: "f-1", name: "Quarterly", parentFolder: nil, lastModified: Date(), pageCount: 1)])

        var rule = SyncRule.new(notebookId: "f-1", notebookName: "Quarterly")
        rule.destinations = [DestinationBinding(configuration: .appleNotes(AppleNotesDestinationConfig(folderName: "Notes")))]
        ledger.upsertRule(rule)
        ledger.recordSyncedPage(bindingId: rule.destinations[0].id, pageId: "p-1", versionHash: "h1", externalId: "note-1")

        XCTAssertNotNil(ledger.remarkableAccount)
        XCTAssertTrue(ledger.rules.contains { $0.id == rule.id })

        ledger.disconnectRemarkable()

        XCTAssertNil(ledger.remarkableAccount, "account should be cleared")
        XCTAssertTrue(ledger.folders.isEmpty, "cached folders should be cleared")
        XCTAssertFalse(ledger.rules.contains { $0.id == rule.id }, "reMarkable rule should be dropped")
        XCTAssertNil(ledger.syncedExternalId(bindingId: rule.destinations[0].id, pageId: "p-1"),
                     "the dropped rule's synced state should be forgotten")
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
