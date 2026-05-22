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
        let bindingId = rule.destinations[0].id

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        let updated = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(updated?.lastRunStatus, .success)
        XCTAssertEqual(updated?.lastRunPagesSynced, 3)

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
        let bindingId = rule.destinations[0].id

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
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
        let bindingId = rule.destinations[0].id

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
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
        let bindingId = rule.destinations[0].id

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        let first = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(first?.lastRunPagesSynced, 3)

        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
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
        let first = await runAndWait(coordinator, ruleId: rule.id, bindingId: binding.id)
        XCTAssertEqual(first?.lastRunPagesSynced, 3)

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

        let resynced = await runAndWait(coordinator, ruleId: rule.id, bindingId: binding.id)
        XCTAssertEqual(resynced?.lastRunPagesSynced, 3)

        ledger.deleteRule(id: rule.id)
    }

    /// A page of reMarkable typed text (a heading and two checkboxes) flows
    /// through the parser, block model, and markdown flattening into a written
    /// file with native task-list markdown — no image, no OCR involved.
    func test_typed_checklist_page_writes_task_markdown() async {
        let ledger = Ledger.shared
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-checklist", notebookName: "Test")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let typed: [TypedParagraph] = [
            TypedParagraph(style: .heading, text: "Groceries"),
            TypedParagraph(style: .checkbox, text: "Milk"),
            TypedParagraph(style: .checkboxChecked, text: "Eggs")
        ]
        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 1, typedText: typed))
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(binding?.lastRunPagesSynced, 1)

        let written = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let markdown = written.first { $0.pathExtension == "md" }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(markdown.contains("## Groceries"), "expected heading, got: \(markdown)")
        XCTAssertTrue(markdown.contains("- [ ] Milk"), "expected unchecked task, got: \(markdown)")
        XCTAssertTrue(markdown.contains("- [x] Eggs"), "expected checked task, got: \(markdown)")

        ledger.deleteRule(id: rule.id)
    }

    // MARK: skip reasons (a manual "Sync now" must never be a silent no-op)

    func test_manual_sync_with_no_connected_destinations_records_skip_reason() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        var rule = SyncRule.new(notebookId: "nb-skip-empty", notebookName: "Journal")
        rule.destinations = []   // connected to nothing
        ledger.upsertRule(rule)
        ledger.clearEvents()

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(skip?.ruleName, "Nothing to sync: no folders are connected to a destination.")

        ledger.deleteRule(id: rule.id)
    }

    func test_manual_sync_of_empty_folder_records_skip_reason() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-skip-nofiles", notebookName: "Journal")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        ledger.clearEvents()

        // The folder has a connected destination but no documents on the device.
        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 0))
        coordinator.syncNow(ruleId: rule.id)

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(skip?.ruleName, "Nothing to sync: Journal has no documents.")
        XCTAssertEqual(skip?.rmNotebookName, "Journal")

        ledger.deleteRule(id: rule.id)
    }

    func test_manual_sync_with_tag_filter_excluding_every_note_records_skip_reason() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)

        var rule = SyncRule.new(notebookId: "nb-skip-filtered", notebookName: "Journal")
        rule.destinations = [DestinationBinding(configuration: .linear(LinearDestinationConfig(
            workspaceId: "team-1", workspaceName: "Team",
            projectId: nil, projectName: nil, defaultLabel: nil,
            requiredTags: ["needed"]
        )))]
        ledger.upsertRule(rule)
        ledger.clearEvents()

        // Three untagged notes; the Linear tag filter accepts none of them.
        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(
            skip?.ruleName,
            "Nothing to sync: every document in Journal was excluded by a destination's tag filter."
        )

        ledger.deleteRule(id: rule.id)
    }

    func test_scheduled_cycle_stays_quiet_when_nothing_to_sync() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        ledger.clearEvents()

        // A scheduled tick that finds nothing must not write a skip event, or an
        // idle account would flood the log every interval.
        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 0))
        await coordinator.scheduledTick()

        let skips = ledger.events.filter { $0.eventType == .cycleSkipped }
        XCTAssertTrue(skips.isEmpty, "scheduled cycles must stay silent, got \(skips.count) skip events")
    }

    // MARK: helpers

    /// Triggers a sync and waits until the binding records a *new* run result and
    /// the cycle has fully settled, then returns the updated binding. Polling
    /// replaces fixed `Task.sleep` waits, which flaked whenever a test's
    /// cold-start Vision OCR warmup outlasted the sleep budget.
    private func runAndWait(_ coordinator: SyncCoordinator,
                            ruleId: String,
                            bindingId: String,
                            timeout: TimeInterval = 20) async -> DestinationBinding? {
        func binding() -> DestinationBinding? {
            Ledger.shared.rules.first { $0.id == ruleId }?.destinations.first { $0.id == bindingId }
        }
        let previousRunAt = binding()?.lastRunAt
        coordinator.syncNow(ruleId: ruleId)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !coordinator.isSyncing, let current = binding(), current.lastRunAt != previousRunAt {
                return current
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return binding()
    }

    /// Polls the shared ledger's event log until an event matches, or times out.
    /// Skip events are appended from a fire-and-forget cycle Task, so a poll is
    /// the black-box way to observe them.
    private func waitForEvent(timeout: TimeInterval = 5,
                              _ predicate: @escaping (SyncEvent) -> Bool) async -> SyncEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = Ledger.shared.events.first(where: predicate) { return event }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

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
    /// Typed text returned for every page, letting a test exercise the
    /// structural checklist path without a rasterized image.
    var typedText: [TypedParagraph] = []

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        RemarkableAccount(pairedAt: Date(), userIdentifier: "test", lastSyncedAt: nil)
    }

    func listFolders() async throws -> [RmFolder] {
        [RmFolder(id: "folder-test", name: "Test", parentFolder: nil, lastModified: Date(), pageCount: files)]
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

    func pageContent(for page: RmPage) async throws -> RemarkablePageContent {
        RemarkablePageContent(imageData: nil, typedText: typedText)
    }
}
