//
//  SyncCoordinatorTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// Black-box coverage for the parallel sync cycle. The point is to lock in
/// the contract every consumer relies on: ordering of ledger events, the
/// computed aggregate status, and the binding-level outcomes when one
/// destination fails and another succeeds.
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    func test_successful_cycle_records_synced_pages_and_marks_binding_success() async {
        let ledger = Ledger.shared
        // Force on-device OCR so the test doesn't depend on a Keychain-stored API key
        // (the user's settings can persist a different provider across runs).
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-test-1", notebookName: "Test")
        rule.destinations = [
            DestinationBinding(configuration: .markdownFolder(
                MarkdownFolderDestinationConfig(
                    folderPath: folder.path,
                    fileNameTemplate: "{notebook}-{page_n}",
                    includeFrontmatter: false
                )
            ))
        ]
        ledger.upsertRule(rule)

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let updated = ledger.rules.first(where: { $0.id == rule.id })
        XCTAssertEqual(updated?.destinations.first?.lastRunStatus, .success)
        XCTAssertEqual(updated?.destinations.first?.lastRunPagesSynced, 3)

        ledger.deleteRule(id: rule.id)
    }

    func test_failing_writes_mark_binding_error_and_record_pageFailed_events() async {
        let ledger = Ledger.shared
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)

        // A path whose parent component is a regular file can never be created
        // as a directory, so every Markdown page write throws.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let unwritable = blocker.appendingPathComponent("nested").path

        var rule = SyncRule.new(notebookId: "nb-fail", notebookName: "Test")
        rule.destinations = [markdownBinding(folderPath: unwritable)]
        ledger.upsertRule(rule)

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let binding = ledger.rules.first(where: { $0.id == rule.id })?.destinations.first
        XCTAssertEqual(binding?.lastRunStatus, .error)
        XCTAssertEqual(binding?.lastRunPagesSynced, 0)

        let pageFailed = ledger.events.filter { $0.ruleId == rule.id && $0.eventType == .pageFailed }
        XCTAssertEqual(pageFailed.count, 3)
        XCTAssertTrue(pageFailed.allSatisfy { $0.errorMessage?.isEmpty == false })

        ledger.deleteRule(id: rule.id)
    }

    func test_one_failing_page_among_successes_marks_binding_partial() async {
        let ledger = Ledger.shared
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Occupy the slot for the middle note's file with a non-empty directory
        // so only that write throws; the other two notes still succeed.
        let blocked = folder.appendingPathComponent("note1-page-1.md", isDirectory: true)
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: blocked.appendingPathComponent("keep.txt").path,
                                       contents: Data("x".utf8))

        var rule = SyncRule.new(notebookId: "nb-partial", notebookName: "Test")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let binding = ledger.rules.first(where: { $0.id == rule.id })?.destinations.first
        XCTAssertEqual(binding?.lastRunStatus, .partial)
        XCTAssertEqual(binding?.lastRunPagesSynced, 2)

        let synced = ledger.events.filter { $0.ruleId == rule.id && $0.eventType == .pageSynced }
        let failed = ledger.events.filter { $0.ruleId == rule.id && $0.eventType == .pageFailed }
        XCTAssertEqual(synced.count, 2)
        XCTAssertEqual(failed.count, 1)

        ledger.deleteRule(id: rule.id)
    }

    /// Idempotency: once a page has synced to a binding, a later cycle over
    /// the same page version skips it. The scripted client returns identical
    /// pages (stable versionHash) every call, so a second cycle should sync
    /// zero pages and emit no new pageSynced events.
    func test_second_cycle_skips_unchanged_pages() async {
        let ledger = Ledger.shared
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-idem", notebookName: "Test")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(ledger.rules.first(where: { $0.id == rule.id })?.destinations.first?.lastRunPagesSynced, 3)

        coordinator.syncNow(ruleId: rule.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let binding = ledger.rules.first(where: { $0.id == rule.id })?.destinations.first
        XCTAssertEqual(binding?.lastRunPagesSynced, 0)
        XCTAssertEqual(binding?.lastRunStatus, .success)

        let synced = ledger.events.filter { $0.ruleId == rule.id && $0.eventType == .pageSynced }
        XCTAssertEqual(synced.count, 3)

        ledger.deleteRule(id: rule.id)
    }

    func test_editing_binding_destination_resyncs_pages() async {
        let ledger = Ledger.shared
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let firstFolder = makeTempFolder()
        let secondFolder = makeTempFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }

        var rule = SyncRule.new(notebookId: "nb-reedit", notebookName: "Test")
        let binding = markdownBinding(folderPath: firstFolder.path)
        rule.destinations = [binding]
        ledger.upsertRule(rule)

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(ledger.rules.first(where: { $0.id == rule.id })?.destinations.first?.lastRunPagesSynced, 3)

        // Re-point the same binding at a new folder. Its synced history must be
        // dropped so the pages land in the new target rather than being skipped.
        let moved = DestinationBinding(
            id: binding.id,
            configuration: .markdownFolder(MarkdownFolderDestinationConfig(
                folderPath: secondFolder.path,
                fileNameTemplate: "{notebook}-page-{page_n}",
                includeFrontmatter: false
            ))
        )
        ledger.updateBinding(ruleId: rule.id, binding: moved)

        coordinator.syncNow(ruleId: rule.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(ledger.rules.first(where: { $0.id == rule.id })?.destinations.first?.lastRunPagesSynced, 3)

        ledger.deleteRule(id: rule.id)
    }

    // MARK: helpers

    private func markdownBinding(folderPath: String) -> DestinationBinding {
        DestinationBinding(configuration: .markdownFolder(
            MarkdownFolderDestinationConfig(
                folderPath: folderPath,
                fileNameTemplate: "{notebook}-page-{page_n}",
                includeFrontmatter: false
            )
        ))
    }

    private func prepare(ledger: Ledger) async {
        // Ensure the coordinator has a paired account to act on. The mock
        // pair returns a deterministic identifier.
        if ledger.remarkableAccount == nil {
            let account = try? await MockRemarkableClient().pairDevice(oneTimeCode: "abcd1234")
            if let account { ledger.setRemarkableAccount(account) }
        }
    }

    private func makeTempFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncbar-coord-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Deterministic reMarkable client that returns N pages on demand. Lets
/// the SyncCoordinator test pin the page count without relying on the
/// shared mock fixture.
private struct ScriptedRemarkableClient: RemarkableClient {
    /// Number of files (notes) in the folder; each has a single page so one
    /// note is produced per file.
    let files: Int

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        RemarkableAccount(pairedAt: Date(), userIdentifier: "test", lastSyncedAt: nil)
    }

    func listNotebooks() async throws -> [RmNotebook] {
        [RmNotebook(id: "folder-test", name: "Test", parentFolder: nil, lastModified: Date(), pageCount: files)]
    }

    func listFiles(inFolderId folderId: String) async throws -> [RmFile] {
        (0..<files).map { index in
            RmFile(
                id: "file-\(index)",
                name: "note\(index)",
                folderId: folderId,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastModified: Date(timeIntervalSince1970: 1_700_001_000),
                pageCount: 1,
                versionHash: "file-hash-\(index)"
            )
        }
    }

    func listTags() async throws -> [String] { [] }

    func listPages(notebookId: String) async throws -> [RmPage] {
        [RmPage(
            notebookId: notebookId,
            pageId: "page-0",
            positionInNotebook: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_001_000),
            hasTypedText: true,
            versionHash: "page-\(notebookId)"
        )]
    }

    func pageImage(for page: RmPage) async throws -> Data? { nil }
}
