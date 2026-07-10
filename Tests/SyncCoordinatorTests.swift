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

    /// The coordinator is source-agnostic: given an injected source client it
    /// lists items, produces content, resolves titles, and fans them to the
    /// destination — without any reMarkable specifics.
    func test_coordinator_drives_injected_source_client() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-spy", notebookName: "Spy")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let spy = SpySourceClient(items: [
            SourceItem(id: "s1", name: "Spied note", versionHash: "h1", createdAt: Date(), tags: [])
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in spy })
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(binding?.lastRunStatus, .success)
        XCTAssertEqual(binding?.lastRunPagesSynced, 1)
        XCTAssertTrue(spy.contentCalled, "coordinator must produce content via the source client")

        let written = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(written.contains { $0.pathExtension == "md" }, "expected a written note, got: \(written)")

        ledger.deleteRule(id: rule.id)
    }

    // MARK: Paid-source run gate

    func test_paid_source_is_skipped_when_not_entitled() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule(source: .x(XSourceConfig(accountId: "1", username: "@u", stream: .bookmarks)))
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let spy = SpySourceClient(items: [
            SourceItem(id: "t1", name: "Tweet", versionHash: "h1", createdAt: Date(), tags: [])
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in spy },
                                          entitlementForSource: { _ in false },
                                          readBudgetExhausted: { false })
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertFalse(spy.contentCalled, "a non-entitled paid source must never run")
        XCTAssertNotEqual(binding?.lastRunStatus, .success)

        ledger.deleteRule(id: rule.id)
    }

    func test_paid_source_is_skipped_when_read_budget_is_spent() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule(source: .x(XSourceConfig(accountId: "1", username: "@u", stream: .bookmarks)))
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let spy = SpySourceClient(items: [
            SourceItem(id: "t1", name: "Tweet", versionHash: "h1", createdAt: Date(), tags: [])
        ])
        // Entitled, but the monthly read budget is spent.
        let coordinator = SyncCoordinator(sourceClient: { _ in spy },
                                          entitlementForSource: { _ in true },
                                          readBudgetExhausted: { true })
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertFalse(spy.contentCalled, "a spent budget must pause the paid source")
        XCTAssertNotEqual(binding?.lastRunStatus, .success)

        ledger.deleteRule(id: rule.id)
    }

    func test_paid_source_runs_when_entitled() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule(source: .x(XSourceConfig(accountId: "1", username: "@u", stream: .bookmarks)))
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let spy = SpySourceClient(items: [
            SourceItem(id: "t1", name: "Tweet", versionHash: "h1", createdAt: Date(), tags: [])
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in spy },
                                          entitlementForSource: { _ in true },
                                          readBudgetExhausted: { false })
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertTrue(spy.contentCalled, "an entitled paid source must run")
        XCTAssertEqual(binding?.lastRunStatus, .success)

        ledger.deleteRule(id: rule.id)
    }

    // MARK: Paid-source crawl spacing (a few checks a day, not every tick)

    private func isXAccount(_ id: String) -> (SourceConfiguration) -> Bool {
        { config in
            if case .x(let cfg) = config { return cfg.accountId == id }
            return false
        }
    }

    func test_scheduled_cycles_space_out_paid_source_crawls() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let account = "throttle-\(UUID().uuidString)"
        var rule = SyncRule(source: .x(XSourceConfig(accountId: account, username: "@u", stream: .bookmarks)))
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        defer { ledger.deleteRule(id: rule.id) }

        let spy = SpySourceClient(items: [
            SourceItem(id: "t1", name: "Tweet", versionHash: "h1", createdAt: Date(), tags: [])
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in spy },
                                          entitlementForSource: { _ in true },
                                          readBudgetExhausted: { false })

        await coordinator.scheduledTick()
        await coordinator.scheduledTick()
        XCTAssertEqual(spy.crawls(where: isXAccount(account)), 1,
                       "a second scheduled tick inside the spacing window must not crawl again")
    }

    func test_manual_sync_bypasses_the_paid_source_spacing() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let account = "bypass-\(UUID().uuidString)"
        var rule = SyncRule(source: .x(XSourceConfig(accountId: account, username: "@u", stream: .bookmarks)))
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        ledger.upsertRule(rule)
        defer { ledger.deleteRule(id: rule.id) }

        let spy = SpySourceClient(items: [
            SourceItem(id: "t1", name: "Tweet", versionHash: "h1", createdAt: Date(), tags: [])
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in spy },
                                          entitlementForSource: { _ in true },
                                          readBudgetExhausted: { false })

        await coordinator.scheduledTick()
        _ = await runAndWait(coordinator, ruleId: rule.id, bindingId: rule.destinations[0].id)
        XCTAssertEqual(spy.crawls(where: isXAccount(account)), 2, "Sync now must always crawl, spacing or not")
    }

    func test_scheduled_cycles_do_not_space_out_free_sources() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)

        let folderId = "free-\(UUID().uuidString)"
        var rule = SyncRule(source: .safari(SafariSourceConfig(folderId: folderId, folderName: "All bookmarks")))
        rule.destinations = [DestinationBinding(configuration:
            .chrome(ChromeDestinationConfig(profileDirName: "Default", targetFolderPath: ["Bookmarks Bar"])))]
        ledger.upsertRule(rule)
        defer { ledger.deleteRule(id: rule.id) }

        let spy = SpySourceClient(items: [])
        let coordinator = SyncCoordinator(sourceClient: { _ in spy },
                                          destinationClient: { _ in SpyDestinationClient() },
                                          entitlementForSource: { _ in true },
                                          readBudgetExhausted: { false })

        await coordinator.scheduledTick()
        await coordinator.scheduledTick()
        let mine = spy.crawls { config in
            if case .safari(let cfg) = config { return cfg.folderId == folderId }
            return false
        }
        XCTAssertEqual(mine, 2, "free sources still crawl every tick")
    }

    // MARK: X bookmarks → Notion (production-shaped rule through the real X client)

    /// Reproduces the production X rule verbatim (same JSON shape the app
    /// persists) and drives the REAL XSourceClient through a stubbed timeline,
    /// asserting bookmarks flow all the way to a destination write. Pins the
    /// full coordinator path a spy source can't (real listItems, real caches).
    func test_production_x_rule_fixture_writes_bookmarks_to_notion() async throws {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)

        let fixture = #"""
        {
         "updatedAt": 804507213.962821,
         "source": {"x": {"_0": {"accountId": "2881611", "username": "@CoolAssPuppy", "stream": "bookmarks"}}},
         "enabled": true,
         "createdAt": 804427149.77417,
         "destinations": [
          {
           "lastRunAt": 804507114.610848,
           "createdAt": 804427149.774131,
           "enabled": true,
           "lastRunStatus": "success",
           "id": "B98D8B1E-1467-45C2-AADA-E932AE2BE703",
           "configuration": {
            "notion": {
             "_0": {
              "destinationType": "database",
              "destinationTitle": "Read it Later",
              "propertyMappings": {
               "Tags": {"multiSelectOptions": {"_0": ["Twitter Bookmark"]}},
               "Site": {"text": {"template": "twitter.com"}},
               "Status": {"multiSelectOptions": {"_0": ["Inbox"]}},
               "Saved": {"text": {"template": "{date}"}},
               "Notes": {"text": {"template": "{text}"}},
               "Source": {"multiSelectOptions": {"_0": ["Twitter"]}},
               "Author": {"text": {"template": "{author}"}},
               "URL": {"text": {"template": "{tweet_url}"}}
              },
              "destinationId": "38da555c-5905-81bb-814c-c7e2aa8361af",
              "workspaceId": "9c5a555c-5905-8164-829b-00039c35148c"
             }
            }
           },
           "lastRunPagesSynced": 1
          }
         ],
         "id": "849850DC-3709-422C-A3AF-5863E678080D"
        }
        """#
        let rule = try JSONDecoder().decode(SyncRule.self, from: Data(fixture.utf8))
        ledger.upsertRule(rule)
        defer { ledger.deleteRule(id: rule.id) }

        // Seed a long-lived token so validAccessToken succeeds without refresh.
        let kc = KeychainStore.shared
        kc.set(value: "test-access", for: .xAccessToken(accountId: "2881611"))
        kc.set(value: String(Date().timeIntervalSince1970 + 3600), for: .xTokenExpiry(accountId: "2881611"))
        defer {
            kc.delete(key: .xAccessToken(accountId: "2881611"))
            kc.delete(key: .xTokenExpiry(accountId: "2881611"))
        }

        // Timeline: two fresh bookmarks; thread search 403s (degrades to root-only).
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("/search/recent") { return (403, Data("{}".utf8)) }
            let json = #"{"data":[{"id":"9002","text":"tweet two","created_at":"2026-07-09T12:00:00.000Z","author_id":"2881611","conversation_id":"9002"},{"id":"9001","text":"tweet one","created_at":"2026-07-08T12:00:00.000Z","author_id":"2881611","conversation_id":"9001"}],"includes":{"users":[{"id":"2881611","username":"CoolAssPuppy","name":"Prashant"}]}}"#
            return (200, Data(json.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let stubConfig = URLSessionConfiguration.ephemeral
        stubConfig.protocolClasses = [StubURLProtocol.self]
        let stubSession = URLSession(configuration: stubConfig)

        let stateName = "x.coord.tests.\(UUID().uuidString)"
        let stateDefaults = UserDefaults(suiteName: stateName)!
        stateDefaults.removePersistentDomain(forName: stateName)
        let xClient = XSourceClient(keychain: kc, session: stubSession,
                                    stateStore: XSyncStateStore(store: stateDefaults),
                                    maxPagesPerCrawl: 10,
                                    readBudget: ReadBudget(defaults: stateDefaults, timeZone: .pacific))

        let coordinator = SyncCoordinator(sourceClient: { _ in xClient },
                                          entitlementForSource: { _ in true },
                                          readBudgetExhausted: { false })
        let binding = await runAndWait(coordinator, ruleId: rule.id,
                                       bindingId: "B98D8B1E-1467-45C2-AADA-E932AE2BE703")

        let recentEvents = Ledger.shared.events.prefix(6)
            .map { "\($0.eventType) \($0.errorMessage ?? $0.rmNotebookName)" }
        XCTAssertEqual(binding?.lastRunPagesSynced, 2,
                       "both bookmarks must reach the Notion write; recent events: \(recentEvents)")
        XCTAssertEqual(binding?.lastRunStatus, .success)
    }

    // MARK: Safari → Chrome (a non-reMarkable source through the same pipeline)

    /// A bookmark's URL flows from the source item through to the destination's
    /// payload, end to end through the coordinator.
    func test_bookmark_url_flows_through_to_destination_payload() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)

        var rule = SyncRule(source: .safari(SafariSourceConfig(folderId: "all", folderName: "All bookmarks")))
        rule.destinations = [DestinationBinding(configuration:
            .chrome(ChromeDestinationConfig(profileDirName: "Default", targetFolderPath: ["Bookmarks Bar"])))]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let spy = SpyDestinationClient()
        let source = StubBookmarkSource(items: [
            SourceItem(id: "b1", name: "Apple", versionHash: "h1", createdAt: .distantPast,
                       url: URL(string: "https://apple.com"), folderPath: ["Bookmarks Bar", "Supabase"])
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in source }, destinationClient: { _ in spy })

        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(binding?.lastRunPagesSynced, 1)
        XCTAssertEqual(spy.lastPayload?.url, URL(string: "https://apple.com"))
        XCTAssertEqual(spy.lastPayload?.title, "Apple")
        XCTAssertEqual(spy.lastPayload?.folderPath, ["Bookmarks Bar", "Supabase"], "folder path mirrors through")

        ledger.deleteRule(id: rule.id)
    }

    /// A Safari source syncs even with no reMarkable account paired (the account
    /// gate only applies to reMarkable rules).
    func test_safari_rule_runs_without_remarkable_account() async {
        let ledger = Ledger.shared
        let savedAccount = ledger.remarkableAccount
        ledger.setRemarkableAccount(nil)
        defer { ledger.setRemarkableAccount(savedAccount) }

        var rule = SyncRule(source: .safari(SafariSourceConfig(folderId: "all", folderName: "All bookmarks")))
        rule.destinations = [DestinationBinding(configuration:
            .chrome(ChromeDestinationConfig(profileDirName: "Default", targetFolderPath: ["Bookmarks Bar"])))]
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let spy = SpyDestinationClient()
        let source = StubBookmarkSource(items: [
            SourceItem(id: "b1", name: "Swift", versionHash: "h1", createdAt: .distantPast, url: URL(string: "https://swift.org"))
        ])
        let coordinator = SyncCoordinator(sourceClient: { _ in source }, destinationClient: { _ in spy })

        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(binding?.lastRunPagesSynced, 1, "Safari sync runs without a reMarkable account")

        ledger.deleteRule(id: rule.id)
    }

    // MARK: source scope (sync a whole folder, or only specific notebooks)

    func test_rule_scoped_to_specific_notebooks_syncs_only_those() async {
        let ledger = Ledger.shared
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Folder has three documents; scope the rule to just the middle one.
        var rule = SyncRule.new(notebookId: "nb-scope", notebookName: "Personal")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        rule.updateRemarkable { $0.selectedFileIds = ["file-1"] }
        ledger.upsertRule(rule)
        let bindingId = rule.destinations[0].id

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        let binding = await runAndWait(coordinator, ruleId: rule.id, bindingId: bindingId)
        XCTAssertEqual(binding?.lastRunPagesSynced, 1, "only the one selected notebook should sync")

        let written = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = written.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains { $0.contains("note1") }, "expected note1 to be written, got: \(names)")
        XCTAssertFalse(names.contains { $0.contains("note0") || $0.contains("note2") }, "unselected notes must not sync: \(names)")

        ledger.deleteRule(id: rule.id)
    }

    func test_manual_sync_with_selected_notebooks_all_missing_records_skip() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-scope-gone", notebookName: "Personal")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        rule.updateRemarkable { $0.selectedFileIds = ["file-deleted"] }   // no such document in the folder
        ledger.upsertRule(rule)
        ledger.clearEvents()

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(skip?.ruleName, "Nothing to sync: the selected notebooks in Personal weren't found.")

        ledger.deleteRule(id: rule.id)
    }

    // MARK: skip reasons (a manual "Sync now" must never be a silent no-op)

    func test_manual_sync_of_rule_with_no_destinations_names_the_folder() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        var rule = SyncRule.new(notebookId: "nb-skip-empty", notebookName: "Journal")
        rule.destinations = []   // connected to nothing
        ledger.upsertRule(rule)
        ledger.clearEvents()

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(skip?.ruleName, "Nothing to sync: Journal has no enabled destinations.")

        ledger.deleteRule(id: rule.id)
    }

    func test_manual_sync_with_no_setup_says_nothing_is_connected() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        ledger.clearEvents()

        // Targeting a rule that doesn't exist (nothing set up) gives the generic
        // "no folders are connected" guidance.
        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: "rule-that-does-not-exist")

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(skip?.ruleName, "Nothing to sync: no folders are connected to a destination.")
    }

    func test_manual_sync_of_disabled_but_connected_rule_says_it_is_turned_off() async {
        let ledger = Ledger.shared
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Connected to a destination, but the rule is switched off. The skip must
        // name the real cause, not claim there's no destination.
        var rule = SyncRule.new(notebookId: "nb-skip-off", notebookName: "Journal")
        rule.destinations = [markdownBinding(folderPath: folder.path)]
        rule.enabled = false
        ledger.upsertRule(rule)
        ledger.clearEvents()

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(files: 3))
        coordinator.syncNow(ruleId: rule.id)

        let skip = await waitForEvent { $0.eventType == .cycleSkipped }
        XCTAssertEqual(skip?.ruleName, "Skipped: syncing for Journal is turned off.")

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
        XCTAssertEqual(skip?.ruleName, "Nothing to sync: Journal has no notebooks.")
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
            "Nothing to sync: every notebook in Journal was excluded by a destination's tag filter."
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

    func uploadDocument(fileURL: URL,
                        toFolderId folderId: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> RmUploadResult {
        progress(1.0)
        return RmUploadResult(documentId: "uploaded", visibleName: fileURL.lastPathComponent)
    }
}

/// A source client double that records whether the coordinator produced content
/// through it. Returns canned items/content so the coordinator's source-agnostic
/// path can be exercised without reMarkable.
private final class SpySourceClient: SourceClient, @unchecked Sendable {
    let kind: SourceKind = .remarkable
    let items: [SourceItem]
    private(set) var contentCalled = false
    private(set) var listedConfigs: [SourceConfiguration] = []

    init(items: [SourceItem]) { self.items = items }

    /// Crawls matching a predicate — the shared test ledger can carry rules
    /// leaked by other tests (and prior runs), so callers count only their own.
    func crawls(where matches: (SourceConfiguration) -> Bool) -> Int {
        listedConfigs.filter(matches).count
    }

    func listScopes() async throws -> [SourceScope] { [] }
    func listItems(config: SourceConfiguration) async throws -> [SourceItem] {
        listedConfigs.append(config)
        return items
    }
    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        contentCalled = true
        return NoteContent(blocks: [.paragraph("from spy")], provider: "spy", model: nil)
    }
    func resolveTitle(for item: SourceItem, content: NoteContent,
                      config: SourceConfiguration, strategyOverride: TitleStrategy?) -> String { item.name }
    func shouldSkipAsEmpty(content: NoteContent, config: SourceConfiguration, ocrModeOverride: OcrMode?) -> Bool { false }
}

/// A bookmark-shaped source: canned items with URLs, empty content (no OCR).
private struct StubBookmarkSource: SourceClient {
    let kind: SourceKind = .safari
    let items: [SourceItem]
    func listScopes() async throws -> [SourceScope] { [] }
    func listItems(config: SourceConfiguration) async throws -> [SourceItem] { items }
    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent { NoteContent(blocks: []) }
    func resolveTitle(for item: SourceItem, content: NoteContent,
                      config: SourceConfiguration, strategyOverride: TitleStrategy?) -> String { item.name }
    func shouldSkipAsEmpty(content: NoteContent, config: SourceConfiguration, ocrModeOverride: OcrMode?) -> Bool { false }
}

/// Captures the payload the coordinator hands a destination.
private final class SpyDestinationClient: DestinationClient, @unchecked Sendable {
    let kind: DestinationKind = .chrome
    private(set) var lastPayload: DestinationPayload?
    func write(payload: DestinationPayload, configuration: DestinationConfiguration,
               existingExternalId: String?) async throws -> DestinationWriteResult {
        lastPayload = payload
        return DestinationWriteResult(externalId: "spy-\(UUID().uuidString.prefix(6))",
                                      externalURL: payload.url, notes: "spy")
    }
}
