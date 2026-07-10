//
//  SyncCoordinator.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Combine
import UserNotifications

/// Orchestrates a sync cycle. The reMarkable + Notion clients are pluggable;
/// destinations route through `DestinationRouter`. OCR runs through
/// `OcrProviderFactory` so the provider can be swapped per-rule or globally.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastTickAt: Date?
    @Published private(set) var nextTickAt: Date?
    @Published private(set) var activeRuleId: String?
    @Published private(set) var activeBindingId: String?

    private let ledger: Ledger
    private let settings: AppSettings
    private let keychain: KeychainStore
    private let remarkable: RemarkableClient
    private let engine: RulesEngine
    /// Resolves the source client for a rule's kind. Injectable so tests can pass
    /// a spy source; the default wraps the injected `remarkable` client so the
    /// reMarkable source still flows through whatever client a test provided.
    private let sourceClientFor: @MainActor (SourceKind) -> SourceClient
    /// Resolves the destination client for a binding's kind. Injectable so tests
    /// can pass a spy; defaults to the production `DestinationRouter`.
    private let destinationClientFor: @MainActor (DestinationKind) -> DestinationClient
    /// The paid-source gate: returns false for a source whose paid class isn't
    /// entitled, so its rules never run (and never spend the maker's API budget).
    /// Free sources always pass. Injectable so tests stay independent of billing.
    private let isEntitledForSource: @MainActor (SourceKind) -> Bool
    /// Whether the month's paid-read budget is spent. Injectable so tests don't
    /// read the developer's real `.standard` budget store.
    private let isReadBudgetExhausted: @MainActor () -> Bool
    private var timerTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    /// When each paid-source rule last crawled, so scheduled ticks space checks
    /// out to a few per day (an idle check still costs real reads). In-memory:
    /// a relaunch grants one fresh crawl, which is fine for a long-lived
    /// menu bar app.
    private var lastPaidCrawlAt: [String: Date] = [:]
    /// Minimum spacing between scheduled paid-source crawls (8h ≈ 3 checks/day).
    static let paidSourceCrawlSpacing: TimeInterval = 8 * 60 * 60

    init(ledger: Ledger? = nil,
         settings: AppSettings? = nil,
         keychain: KeychainStore = .shared,
         remarkable: RemarkableClient = RemarkableClientFactory.make(),
         engine: RulesEngine = RulesEngine(),
         sourceClient: (@MainActor (SourceKind) -> SourceClient)? = nil,
         destinationClient: (@MainActor (DestinationKind) -> DestinationClient)? = nil,
         entitlementForSource: (@MainActor (SourceKind) -> Bool)? = nil,
         readBudgetExhausted: (@MainActor () -> Bool)? = nil) {
        self.ledger = ledger ?? Ledger.shared
        self.isEntitledForSource = entitlementForSource ?? { EntitlementManager.shared.isEntitled(forSource: $0) }
        self.isReadBudgetExhausted = readBudgetExhausted ?? { ReadBudget().isExhausted(now: Date()) }
        self.settings = settings ?? AppSettings.shared
        self.keychain = keychain
        self.remarkable = remarkable
        self.engine = engine
        self.sourceClientFor = sourceClient ?? { kind in
            switch kind {
            case .remarkable: return RemarkableSourceClient(remarkable: remarkable)
            case .safari:     return SafariSourceClient()
            case .notion:     return NotionSourceClient(keychain: keychain)
            case .x:          return XSourceClient(keychain: keychain)
            }
        }
        self.destinationClientFor = destinationClient ?? { DestinationRouter.client(for: $0) }

        NotificationCenter.default.publisher(for: .syncIntervalChanged)
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .pauseSyncingChanged)
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &subscriptions)
    }

    func start() {
        restartTimer()
        Task { await refreshFolders() }
    }
    func stop()  { timerTask?.cancel(); timerTask = nil }

    /// Refreshes the folder list and prunes rules whose folder no longer exists.
    /// Gated on a real device token so it never prunes against the mock client's
    /// sample folders. Runs at launch so the menu bar dropdown is clean even
    /// without opening the main window.
    func refreshFolders() async {
        // Demo mode shows ephemeral sample folders/rules; refreshing from the
        // real device would prune them, so skip while it's on.
        guard !ledger.isDemoMode else { return }
        guard keychain.value(for: .remarkableDeviceToken)?.isEmpty == false else { return }
        do {
            let folders = try await remarkable.listFolders()
            ledger.updateRemarkableHealth(error: nil)
            guard !folders.isEmpty else { return }
            ledger.setFolders(folders)
            // Remap rules orphaned by an account switch; never delete on a missing
            // folder id (a re-paired account makes every id look "missing", which
            // would silently destroy the user's syncs).
            ledger.reconcileRemarkableRules(withFolders: folders)
        } catch {
            ledger.updateRemarkableHealth(error: error)
            Log.sync.error("Folder refresh failed: \(Formatters.userMessage(for: error), privacy: .public)")
        }
    }

    /// What kicked off a cycle, attached to the `sync.run` analytics event.
    private enum SyncTrigger: String {
        case manual
        case scheduled
    }

    func syncNow(ruleId: String? = nil, bindingId: String? = nil) {
        guard !isSyncing else { return }
        Task { await runCycle(ruleId: ruleId, bindingId: bindingId, trigger: .manual) }
    }

    /// One scheduled sync pass. Separate from `syncNow` so the timer and tests
    /// share the exact scheduled-trigger path (which stays quiet when idle).
    func scheduledTick() async {
        await runCycle(ruleId: nil, bindingId: nil, trigger: .scheduled)
    }

    /// The documents in a folder, for the rule sheet's "choose notebooks" picker.
    /// Returns an empty list (rather than throwing) so the UI can show its own
    /// empty/failed state without a do/catch at the call site.
    func files(inFolder folderId: String) async -> [RmFile] {
        do {
            return try await remarkable.listFiles(inFolderId: folderId)
        } catch {
            Log.sync.error("Listing notebooks failed: \(Formatters.userMessage(for: error), privacy: .public)")
            return []
        }
    }

    /// The targetable scopes for a source kind (reMarkable folders, Safari
    /// bookmark folders), for the editor's source picker. Returns empty on error
    /// (e.g. Safari without Full Disk Access) so the UI shows its own empty state.
    func scopes(for kind: SourceKind) async -> [SourceScope] {
        (try? await sourceClientFor(kind).listScopes()) ?? []
    }

    private func restartTimer() {
        timerTask?.cancel()
        guard self.settings.syncIntervalSeconds > 0,
              !self.settings.pauseSyncing else {
            nextTickAt = nil
            return
        }
        nextTickAt = Date().addingTimeInterval(TimeInterval(self.settings.syncIntervalSeconds))
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Re-read on every loop so a settings change picks up on
                // the next tick without restarting the task.
                let seconds = self.settings.syncIntervalSeconds
                guard seconds > 0, !self.settings.pauseSyncing else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self.scheduledTick()
                self.nextTickAt = Date().addingTimeInterval(TimeInterval(seconds))
            }
        }
    }

    private func runCycle(ruleId: String?, bindingId: String?, trigger: SyncTrigger) async {
        // Never run two cycles at once. `syncNow` already guards, but a scheduled
        // tick reaches `runCycle` directly; without this, an overlapping cycle could
        // each read the read-budget before either records and together exceed the cap.
        guard !isSyncing else { return }
        guard !ledger.isDemoMode else { return }
        // A manual "Sync now" always explains itself in the visible log; scheduled
        // ticks stay quiet so an idle account doesn't flood the log every interval.
        let explainSkips = (trigger == .manual)

        guard !self.settings.pauseSyncing else {
            if explainSkips { recordSkip(.syncingPaused) }
            return
        }

        let candidateRules = ledger.rules.filter { rule in
            rule.enabled && (ruleId == nil || rule.id == ruleId) && !rule.destinations.isEmpty
        }
        guard !candidateRules.isEmpty else {
            if explainSkips { recordSkip(noWorkReason(forTargetedRuleId: ruleId), ruleId: ruleId) }
            return
        }

        // reMarkable rules need a paired account; local sources (Safari) don't.
        let rules = candidateRules.filter { $0.sourceKind != .remarkable || ledger.remarkableAccount != nil }
        guard !rules.isEmpty else {
            if explainSkips {
                recordSkip(.noAccountPaired)
            } else {
                Log.sync.info("Skipping scheduled cycle: no reMarkable account paired.")
            }
            return
        }

        isSyncing = true
        NotificationCenter.default.post(name: .syncStarted, object: nil)
        let cycleStart = Date()

        // Drop the reMarkable listing cache so this cycle re-reads the cloud once;
        // every reMarkable rule below then shares that single walk instead of each
        // re-walking the account and tripping the rate limiter.
        await remarkable.refreshListing()

        for rule in rules {
            activeRuleId = rule.id
            await runRule(rule, restrictedToBindingId: bindingId, explainSkips: explainSkips)
        }

        activeRuleId = nil
        activeBindingId = nil
        lastTickAt = Date()
        isSyncing = false
        NotificationCenter.default.post(name: .syncFinished, object: nil)

        Telemetry.capture("sync.run", properties: [
            "trigger": trigger.rawValue,
            "rules": rules.count,
            "duration_ms": Int(Date().timeIntervalSince(cycleStart) * 1_000)
        ])
    }

    private func runRule(_ rule: SyncRule, restrictedToBindingId: String?, explainSkips: Bool) async {
        let folderName = rule.sourceSummary

        // Paid-source gate: a lapsed (or never-subscribed) paid class never runs,
        // so we never spend the maker's API budget on it. The config is untouched;
        // the row shows inactive and re-subscribing resumes it.
        guard isEntitledForSource(rule.sourceKind) else {
            if explainSkips {
                let feature = rule.sourceKind.paidFeature?.displayName ?? folderName
                recordSkip(.paidSourceInactive(feature: feature), ruleId: rule.id)
            }
            return
        }

        // Monthly read cap: bound a flat-rate subscriber's API cost. Once the
        // month's budget is spent, paid-source rules pause until it resets.
        if let feature = rule.sourceKind.paidFeature, isReadBudgetExhausted() {
            if explainSkips { recordSkip(.monthlyReadLimit(feature: feature.displayName), ruleId: rule.id) }
            return
        }

        // Paid sources check a few times a day, not every tick — an idle crawl
        // still bills reads. `explainSkips` is true exactly for a manual
        // "Sync now", which always goes through.
        if rule.sourceKind.paidFeature != nil, !explainSkips,
           let lastCrawl = lastPaidCrawlAt[rule.id],
           Date().timeIntervalSince(lastCrawl) < Self.paidSourceCrawlSpacing {
            return
        }

        let source = sourceClientFor(rule.sourceKind)

        var items: [SourceItem] = []
        do {
            items = try await source.listItems(config: rule.source)
            reportSourceHealth(rule.sourceKind, error: nil)
            if rule.sourceKind.paidFeature != nil { lastPaidCrawlAt[rule.id] = Date() }
        } catch {
            reportSourceHealth(rule.sourceKind, error: error)
            recordFailure(rule: rule, binding: nil, message: Formatters.userMessage(for: error))
            return
        }

        let bindings = rule.destinations.filter { binding in
            binding.enabled && (restrictedToBindingId == nil || binding.id == restrictedToBindingId)
        }
        guard !bindings.isEmpty else {
            if explainSkips { recordSkip(.noEnabledDestinations(folder: folderName), ruleId: rule.id) }
            return
        }
        guard !items.isEmpty else {
            if explainSkips { recordSkip(.folderEmpty(folder: folderName), ruleId: rule.id) }
            return
        }

        // Narrow to the items this rule is scoped to: the whole scope, or a
        // hand-picked set (e.g. "only my journal").
        let scopedItems = items.filter { rule.includes(itemId: $0.id) }
        guard !scopedItems.isEmpty else {
            if explainSkips { recordSkip(.selectedNotesMissing(folder: folderName), ruleId: rule.id) }
            return
        }

        // Skip content production for items that no enabled binding will accept
        // (e.g. a destination whose tag filter excludes untagged notes) so we
        // never pay the OCR provider for output nothing will consume.
        let neededItems = scopedItems.filter { item in bindings.contains { $0.accepts(fileTags: item.tags) } }
        guard !neededItems.isEmpty else {
            if explainSkips { recordSkip(.allNotesFilteredOut(folder: folderName), ruleId: rule.id) }
            return
        }

        // First-run adoption (Notion -> Apple Notes) runs before content
        // production: it links existing notes by title+date using item metadata
        // only — no page bodies — and seeds their version so they're treated as
        // already in sync. This is what keeps a 3,000-page backup from fetching
        // 3,000 page bodies on the first run when almost all already exist.
        for binding in bindings {
            await adoptIfFirstRun(rule: rule, binding: binding, items: neededItems)
        }

        // Produce content (OCR for reMarkable, block fetch for Notion) only for
        // items some enabled binding will actually write — i.e. whose version
        // differs from what was last synced there. Adopted/unchanged items are
        // skipped without paying the per-item source cost, so first-run and steady
        // -state cycles scale with what changed, not with the whole source.
        let itemsToProduce = neededItems.filter { item in
            bindings.contains { binding in
                binding.accepts(fileTags: item.tags)
                    && ledger.syncedHash(bindingId: binding.id, pageId: item.id) != item.versionHash
            }
        }

        // Render each needed item once, reused across every binding — source cost
        // shouldn't scale with destination count. A render failure skips that item
        // rather than aborting the whole rule.
        var contents: [(item: SourceItem, content: NoteContent)] = []
        for item in itemsToProduce {
            do {
                let content = try await source.content(for: item, config: rule.source)
                contents.append((item, content))
            } catch {
                Log.sync.error("Content production failed for item \(item.id, privacy: .public): \(Formatters.userMessage(for: error), privacy: .public)")
            }
        }

        for binding in bindings {
            activeBindingId = binding.id
            await runBinding(rule: rule, folderName: folderName, binding: binding, source: source, contents: contents)
        }
        activeBindingId = nil
    }

    /// Updates source-connection health. Only reMarkable has a health record
    /// today; other kinds are a no-op until they grow one.
    private func reportSourceHealth(_ kind: SourceKind, error: Error?) {
        switch kind {
        case .remarkable: ledger.updateRemarkableHealth(error: error)
        case .safari:     break   // Safari is a local file; no connection health to track.
        case .notion:     break   // Notion source health isn't tracked yet.
        case .x:          break   // X source health isn't tracked yet.
        }
    }

    private func runBinding(rule: SyncRule, folderName: String, binding: DestinationBinding,
                            source: SourceClient, contents: [(item: SourceItem, content: NoteContent)]) async {
        let client = destinationClientFor(binding.kind)
        ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName, type: .ruleRunStarted))

        // Mirror destinations (Chrome with "exactly match") reconcile the whole
        // set at once — add, update, and delete — rather than writing per item.
        if client.reconciles(binding.configuration) {
            await runReconcile(rule: rule, folderName: folderName, binding: binding,
                               client: client, source: source, contents: contents)
            return
        }

        var notesSynced = 0
        var firstError: String?
        let runStart = Date()

        for (item, content) in contents where binding.accepts(fileTags: item.tags) {
            let suppressed = source.shouldSkipAsEmpty(content: content, config: rule.source,
                                                      ocrModeOverride: binding.ocrModeOverride)
            let directive = engine.evaluate(
                enabled: rule.enabled,
                itemVersionHash: item.versionHash,
                previouslySyncedHash: ledger.syncedHash(bindingId: binding.id, pageId: item.id),
                suppressedAsEmpty: suppressed
            )
            guard case .proceed = directive else { continue }

            let title = source.resolveTitle(for: item, content: content, config: rule.source,
                                            strategyOverride: binding.titleStrategyOverride)
            let payload = DestinationPayload(
                title: title,
                body: content.markdownBody,
                blocks: content.blocks,
                mermaidSource: content.firstMermaid,
                sourceDate: item.createdAt,
                pdfData: nil,
                ocrProvider: content.provider,
                ruleNotebookName: item.name,
                folderName: folderName,
                pageNumber: 1,
                url: item.url,
                folderPath: item.folderPath,
                sourceId: item.id,
                metadata: item.metadata
            )
            do {
                let existingId = ledger.syncedExternalId(bindingId: binding.id, pageId: item.id)
                let result = try await client.write(payload: payload, configuration: binding.configuration, existingExternalId: existingId)
                notesSynced += 1
                ledger.recordSyncedPage(bindingId: binding.id, pageId: item.id, versionHash: item.versionHash, externalId: result.externalId)
                ledger.appendEvent(makeEvent(
                    rule: rule, binding: binding, folderName: folderName, type: .pageSynced,
                    noteId: item.id, noteName: item.name, url: result.externalURL?.absoluteString,
                    ocrProvider: content.provider, durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)
                ))
            } catch {
                let msg = Formatters.userMessage(for: error)
                if firstError == nil { firstError = msg }
                ledger.appendEvent(makeEvent(
                    rule: rule, binding: binding, folderName: folderName, type: .pageFailed,
                    noteId: item.id, noteName: item.name, ocrProvider: content.provider, errorMessage: msg
                ))
            }
        }

        let status: RuleRunStatus = {
            if firstError != nil { return notesSynced > 0 ? .partial : .error }
            return .success
        }()
        ledger.updateBindingRunResult(
            ruleId: rule.id, bindingId: binding.id,
            status: status, pagesSynced: notesSynced, runAt: Date(),
            error: firstError
        )
        ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName, type: .ruleRunCompleted,
                                     durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)))

        Telemetry.capture("destination.synced", properties: [
            "provider": binding.kind.rawValue,
            "notes_synced": notesSynced,
            "status": status.rawValue
        ])

        if firstError != nil, self.settings.notifyOnFailure {
            postNotification(title: "Sync failed", body: "\(folderName) → \(binding.configuration.summary)")
        } else if firstError == nil, notesSynced > 0, self.settings.notifyOnSuccess {
            postNotification(title: "Sync complete", body: "\(folderName): \(Formatters.syncResultLabel(pageCount: notesSynced))")
        }
    }

    /// Before a Notion -> Apple Notes binding's first write, reconcile each Notion
    /// page against the existing Apple notes (same notebook + title). A match means
    /// the note already exists, so it's recorded as **already in sync at its current
    /// Notion version** — linked (for future edits) AND marked synced, so the first
    /// run leaves it untouched rather than overwriting it with a round-tripped copy.
    /// Only genuinely new pages get created; a later Notion edit changes the version
    /// hash and flows down then (Notion wins on a real change). Identity can't live
    /// in the note body (Apple Notes strips hidden markers), so it's seeded here.
    /// Runs once: a binding with any recorded state has already reconciled. Only
    /// Notion -> Apple Notes does this; reading the whole Notes account is wasted
    /// for any other pairing.
    /// Dispatches first-run adoption to the right strategy for a Notion source's
    /// destination. Both keep matched items as-is (seed their version, no
    /// overwrite) so a first run only creates genuinely new pages.
    private func adoptIfFirstRun(rule: SyncRule, binding: DestinationBinding, items: [SourceItem]) async {
        guard case .notion = rule.source else { return }
        guard !ledger.hasAnySyncedState(bindingId: binding.id) else { return }
        switch binding.configuration {
        case .appleNotes:                 await adoptExistingNotes(binding: binding, items: items)
        case .markdownFolder(let config): adoptExistingMarkdown(binding: binding, items: items, config: config)
        default:                          break
        }
    }

    /// Notion -> Markdown: link each page to an existing `.md` with the same
    /// `notion_id` (exact, frontmatter-based) so the file is updated in place on a
    /// future edit rather than duplicated. Seeds the current version so the first
    /// run leaves existing files untouched.
    private func adoptExistingMarkdown(binding: DestinationBinding, items: [SourceItem],
                                       config: MarkdownFolderDestinationConfig) {
        let index = MarkdownAdoptionIndex.read(folderPath: config.folderPath)
        guard !index.isEmpty else { return }
        var kept = 0
        for item in items {
            guard let path = index[item.id] else { continue }
            ledger.recordSyncedPage(bindingId: binding.id, pageId: item.id,
                                    versionHash: item.versionHash, externalId: path)
            kept += 1
        }
        Log.sync.info("First-run Markdown adoption: kept \(kept, privacy: .public) existing files as-is, will create \(items.count - kept, privacy: .public) new")
    }

    private func adoptExistingNotes(binding: DestinationBinding, items: [SourceItem]) async {
        let candidates = items.map { item in
            AdoptionCandidate(notionId: item.id,
                              title: item.name,
                              category: item.folderPath.last,
                              createdAt: item.createdAt)
        }
        let existing: [ExistingAppleNote]
        do {
            existing = try await AppleNotesInventory.read()
        } catch {
            Log.sync.error("First-run adoption skipped — couldn't read Apple Notes: \(Formatters.userMessage(for: error), privacy: .public)")
            return
        }
        let result = NoteAdoptionMatcher.match(notion: candidates, apple: existing)
        // Mark each matched page as synced at its current version, so the first run
        // skips it (no overwrite) but still updates it in place on a future edit.
        let hashByPage = Dictionary(items.map { ($0.id, $0.versionHash) },
                                    uniquingKeysWith: { first, _ in first })
        for link in result.links {
            guard let versionHash = hashByPage[link.notionId] else { continue }
            ledger.recordSyncedPage(bindingId: binding.id, pageId: link.notionId,
                                    versionHash: versionHash, externalId: link.appleNoteId)
        }
        Log.sync.info("First-run adoption: kept \(result.links.count, privacy: .public) existing notes as-is, will create \(result.freshNotionIds.count, privacy: .public) new, \(result.orphanAppleNoteIds.count, privacy: .public) orphan Apple notes")
    }

    /// Set-level mirror: hand the destination the full desired set and let it
    /// add/update/delete to match. Used for "make Chrome exactly match Safari".
    private func runReconcile(rule: SyncRule, folderName: String, binding: DestinationBinding,
                              client: DestinationClient, source: SourceClient,
                              contents: [(item: SourceItem, content: NoteContent)]) async {
        let runStart = Date()
        let payloads: [DestinationPayload] = contents
            .filter { binding.accepts(fileTags: $0.item.tags) }
            .map { entry in
                let title = source.resolveTitle(for: entry.item, content: entry.content,
                                                config: rule.source, strategyOverride: binding.titleStrategyOverride)
                return DestinationPayload(
                    title: title, body: entry.content.markdownBody, blocks: entry.content.blocks,
                    mermaidSource: entry.content.firstMermaid, sourceDate: entry.item.createdAt,
                    pdfData: nil, ocrProvider: entry.content.provider, ruleNotebookName: entry.item.name,
                    folderName: folderName, pageNumber: 1, url: entry.item.url, folderPath: entry.item.folderPath
                )
            }

        var status: RuleRunStatus = .success
        var firstError: String?
        var changed = 0
        do {
            let result = try await client.reconcile(desired: payloads, configuration: binding.configuration)
            changed = result.added + result.updated + result.deleted
            ledger.appendEvent(makeEvent(
                rule: rule, binding: binding, folderName: folderName, type: .pageSynced,
                noteName: "Mirrored: +\(result.added) ~\(result.updated) −\(result.deleted)",
                durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)))
        } catch {
            firstError = Formatters.userMessage(for: error)
            status = .error
            ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName,
                                         type: .pageFailed, errorMessage: firstError))
        }

        ledger.updateBindingRunResult(ruleId: rule.id, bindingId: binding.id,
                                      status: status, pagesSynced: changed, runAt: Date(), error: firstError)
        ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName,
                                     type: .ruleRunCompleted, durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)))
        Telemetry.capture("destination.synced", properties: [
            "provider": binding.kind.rawValue, "notes_synced": changed, "status": status.rawValue, "mode": "mirror"
        ])
        if firstError != nil, self.settings.notifyOnFailure {
            postNotification(title: "Sync failed", body: "\(folderName) → \(binding.configuration.summary)")
        } else if firstError == nil, changed > 0, self.settings.notifyOnSuccess {
            postNotification(title: "Sync complete", body: "\(folderName): mirrored to \(binding.configuration.summary)")
        }
    }

    private func makeEvent(rule: SyncRule,
                           binding: DestinationBinding,
                           folderName: String,
                           type: SyncEventType,
                           noteId: String? = nil,
                           noteName: String? = nil,
                           url: String? = nil,
                           ocrProvider: String? = nil,
                           durationMs: Int? = nil,
                           errorMessage: String? = nil) -> SyncEvent {
        SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: rule.id, ruleName: "\(folderName) → \(binding.configuration.summary)",
            eventType: type,
            rmNotebookName: noteName ?? folderName, rmPageId: noteId,
            notionPageUrl: url, durationMs: durationMs,
            ocrProvider: ocrProvider, errorMessage: errorMessage
        )
    }

    /// Why a manual cycle or rule produced no work. The message is what the user
    /// sees in the log, so it names the folder and the fix where it can.
    enum SyncSkipReason {
        case noAccountPaired
        case syncingPaused
        case noConnectedFolders
        case ruleDisabled(folder: String)
        case folderEmpty(folder: String)
        case selectedNotesMissing(folder: String)
        case noEnabledDestinations(folder: String)
        case allNotesFilteredOut(folder: String)
        case paidSourceInactive(feature: String)
        case monthlyReadLimit(feature: String)

        var message: String {
            switch self {
            case .monthlyReadLimit(let feature):
                return "\(feature) reached this month's sync limit. It resumes next month."
            case .paidSourceInactive(let feature):
                return "\(feature) sync paused — subscription inactive. Re-subscribe to resume."
            case .noAccountPaired:
                return "Nothing to sync: no reMarkable account is paired."
            case .syncingPaused:
                return "Skipped: syncing is paused."
            case .noConnectedFolders:
                return "Nothing to sync: no folders are connected to a destination."
            case .ruleDisabled(let folder):
                return "Skipped: syncing for \(folder) is turned off."
            case .folderEmpty(let folder):
                return "Nothing to sync: \(folder) has no notebooks."
            case .selectedNotesMissing(let folder):
                return "Nothing to sync: the selected notebooks in \(folder) weren't found."
            case .noEnabledDestinations(let folder):
                return "Nothing to sync: \(folder) has no enabled destinations."
            case .allNotesFilteredOut(let folder):
                return "Nothing to sync: every notebook in \(folder) was excluded by a destination's tag filter."
            }
        }

        /// The reMarkable folder this skip concerns, when it is rule-specific.
        var folderName: String? {
            switch self {
            case .ruleDisabled(let folder),
                 .folderEmpty(let folder),
                 .selectedNotesMissing(let folder),
                 .noEnabledDestinations(let folder),
                 .allNotesFilteredOut(let folder):
                return folder
            case .noAccountPaired, .syncingPaused, .noConnectedFolders,
                 .paidSourceInactive, .monthlyReadLimit:
                return nil
            }
        }
    }

    /// Picks the most accurate "nothing happened" reason when the cycle's rule
    /// filter came up empty. For a targeted manual sync (`ruleId` set) the rule
    /// may exist but be disabled or have no destinations, which is more useful to
    /// say than the generic "no folders are connected".
    private func noWorkReason(forTargetedRuleId ruleId: String?) -> SyncSkipReason {
        guard let ruleId, let rule = ledger.rules.first(where: { $0.id == ruleId }) else {
            return .noConnectedFolders
        }
        if rule.destinations.isEmpty { return .noEnabledDestinations(folder: rule.sourceSummary) }
        if !rule.enabled { return .ruleDisabled(folder: rule.sourceSummary) }
        return .noConnectedFolders
    }

    /// Writes a visible "Nothing to sync" event explaining why a manual cycle did
    /// no work, so "Sync now" is never a silent no-op. The folder name stays out
    /// of the system log (it is the user's content); the in-app event carries it.
    private func recordSkip(_ reason: SyncSkipReason, ruleId: String? = nil) {
        Log.sync.info("Cycle skipped: \(reason.message, privacy: .private)")
        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: ruleId, ruleName: reason.message,
            eventType: .cycleSkipped,
            rmNotebookName: reason.folderName, rmPageId: nil,
            notionPageUrl: nil, durationMs: nil,
            ocrProvider: nil, errorMessage: nil
        ))
    }

    private func recordFailure(rule: SyncRule, binding: DestinationBinding?, message: String) {
        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: rule.id, ruleName: binding.map { ruleHeader(rule, binding: $0) } ?? rule.sourceSummary,
            eventType: .pageFailed,
            rmNotebookName: rule.sourceSummary, rmPageId: nil,
            notionPageUrl: nil, durationMs: nil,
            ocrProvider: nil, errorMessage: message
        ))
    }

    private func ruleHeader(_ rule: SyncRule, binding: DestinationBinding) -> String {
        "\(rule.sourceSummary) → \(binding.configuration.summary)"
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
