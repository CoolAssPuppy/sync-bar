//
//  Ledger.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Combine

/// In-memory + UserDefaults-backed ledger of accounts, rules, and sync events.
///
/// All persistence flows through this single type so swapping in CloudKit later
/// (see `CloudKitLedger`) only touches one file.
@MainActor
final class Ledger: ObservableObject {
    static let shared = Ledger()

    // MARK: Storage keys
    private static let remarkableAccountKey = "ledger.remarkableAccount"
    private static let notionWorkspacesKey  = "ledger.notionWorkspaces"
    private static let linearAccountsKey    = "ledger.linearAccounts"
    private static let googleAccountsKey    = "ledger.googleAccounts"
    private static let markdownTargetsKey   = "ledger.markdownTargets"
    private static let appleNotesTargetsKey = "ledger.appleNotesTargets"
    private static let rulesKey             = "ledger.rules"
    private static let eventsKey            = "ledger.events"
    private static let foldersKey         = "ledger.notebooks"
    private static let syncedPageHashesKey  = "ledger.syncedPageHashes"
    private static let syncedExternalIdsKey = "ledger.syncedExternalIds"

    @Published private(set) var remarkableAccount: RemarkableAccount?
    @Published private(set) var notionWorkspaces: [NotionWorkspace] = []
    @Published private(set) var linearAccounts: [LinearAccount] = []
    @Published private(set) var googleAccounts: [GoogleAccount] = []
    @Published private(set) var markdownTargets: [MarkdownTarget] = []
    @Published private(set) var appleNotesTargets: [AppleNotesTarget] = []
    @Published private(set) var rules: [SyncRule] = []
    @Published private(set) var events: [SyncEvent] = []
    @Published private(set) var folders: [RmFolder] = []

    /// Version hash of the last page successfully written to a binding, keyed
    /// by `"<bindingId>|<pageId>"`. The sync engine consults this so a page
    /// whose content hasn't changed since its last sync is skipped. Not
    /// `@Published`: no view observes it, and it churns during sync cycles.
    private var syncedPageHashes: [String: String] = [:]

    /// External destination id (Notion page id, Google doc id, Linear issue id,
    /// Apple Notes note id, Markdown file path) of the note last written for a
    /// binding+file, keyed by `"<bindingId>|<pageId>"`. Lets the next sync update
    /// that same note in place rather than creating a duplicate.
    private var syncedExternalIds: [String: String] = [:]

    private static let maxEventsRetained = 500
    private static let persistDebounceMs: UInt64 = 250_000_000  // 250 ms
    private var pendingPersistTasks: [String: Task<Void, Never>] = [:]

    static let demoSuiteName = "com.strategicnerds.SyncBar.demo"

    /// The real persistence store. Under XCTest we use a throwaway suite so test
    /// runs never leak rules/events/accounts into the real app.
    private static func realStore() -> UserDefaults {
        if NSClassFromString("XCTestCase") != nil {
            return UserDefaults(suiteName: "com.strategicnerds.SyncBar.tests") ?? .standard
        }
        return .standard
    }

    /// Active backing store. Swapped to an isolated demo suite while demo mode
    /// is on (for screenshots) and back to the real store when off, so demo
    /// data never touches real data. Demo mode is session-only — a launch
    /// always starts on the real store.
    private var store: UserDefaults = Ledger.realStore()

    /// Whether the ledger is currently serving ephemeral demo data.
    @Published private(set) var isDemoMode = false

    private init() {
        load()
    }

    // MARK: Demo mode

    /// Enters or exits ephemeral demo mode. In demo mode the ledger reads and
    /// writes an isolated suite seeded with sample data, leaving the real data
    /// untouched; exiting reloads the real data. Demo mode never persists across
    /// launches, and the demo suite is wiped on both entry and exit so it can't
    /// linger.
    func setDemoMode(_ on: Bool) {
        guard on != isDemoMode else { return }

        // Before leaving the real store, flush any debounced writes synchronously
        // so a just-made change isn't lost; then drop the (now stale) tasks so
        // they can't fire against the store we're switching to.
        if !isDemoMode { flushPending() }
        pendingPersistTasks.values.forEach { $0.cancel() }
        pendingPersistTasks.removeAll()

        if on {
            let demo = UserDefaults(suiteName: Self.demoSuiteName) ?? Self.realStore()
            demo.removePersistentDomain(forName: Self.demoSuiteName)   // start fresh
            store = demo
            isDemoMode = true
            load()
            DemoData.load(into: self)
        } else {
            let leaving = store
            store = Self.realStore()
            isDemoMode = false
            leaving.removePersistentDomain(forName: Self.demoSuiteName)  // leave nothing behind
            load()
        }
        broadcastChanged()
    }

    /// Synchronously writes every collection to the current store. Used before a
    /// store swap so a debounced write still in flight isn't dropped.
    private func flushPending() {
        persist(value: remarkableAccount, key: Self.remarkableAccountKey)
        persist(value: notionWorkspaces, key: Self.notionWorkspacesKey)
        persist(value: linearAccounts, key: Self.linearAccountsKey)
        persist(value: googleAccounts, key: Self.googleAccountsKey)
        persist(value: markdownTargets, key: Self.markdownTargetsKey)
        persist(value: appleNotesTargets, key: Self.appleNotesTargetsKey)
        persist(value: rules, key: Self.rulesKey)
        persist(value: events, key: Self.eventsKey)
        persist(value: folders, key: Self.foldersKey)
        persist(value: syncedPageHashes, key: Self.syncedPageHashesKey)
        persist(value: syncedExternalIds, key: Self.syncedExternalIdsKey)
    }

    /// Posts every "changed" notification so views that observe NotificationCenter
    /// (rather than the @Published arrays) refresh after a wholesale store swap.
    private func broadcastChanged() {
        for name: Notification.Name in [.remarkableAccountChanged, .notionWorkspacesChanged,
                                        .destinationsChanged, .rulesChanged, .eventsChanged, .foldersChanged] {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    // MARK: Public API

    func setRemarkableAccount(_ account: RemarkableAccount?) {
        guard remarkableAccount != account else { return }
        remarkableAccount = account
        persistRemarkable()
        NotificationCenter.default.post(name: .remarkableAccountChanged, object: nil)
    }

    func upsertNotionWorkspace(_ workspace: NotionWorkspace) {
        upsert(workspace, in: \.notionWorkspaces, key: Self.notionWorkspacesKey,
               notification: .notionWorkspacesChanged)
    }
    func removeNotionWorkspace(id: String) {
        remove(id: id, from: \.notionWorkspaces, key: Self.notionWorkspacesKey,
               notification: .notionWorkspacesChanged,
               bindingMatches: { config, removed in
                   if case .notion(let cfg) = config { return cfg.workspaceId == removed.id }
                   return false
               })
    }

    func upsertLinearAccount(_ account: LinearAccount) {
        upsert(account, in: \.linearAccounts, key: Self.linearAccountsKey,
               notification: .destinationsChanged)
    }
    func removeLinearAccount(id: String) {
        remove(id: id, from: \.linearAccounts, key: Self.linearAccountsKey,
               notification: .destinationsChanged,
               bindingMatches: { config, removed in
                   if case .linear(let cfg) = config { return cfg.workspaceId == removed.id }
                   return false
               })
    }

    func upsertGoogleAccount(_ account: GoogleAccount) {
        upsert(account, in: \.googleAccounts, key: Self.googleAccountsKey,
               notification: .destinationsChanged)
    }
    func removeGoogleAccount(id: String) {
        remove(id: id, from: \.googleAccounts, key: Self.googleAccountsKey,
               notification: .destinationsChanged,
               bindingMatches: { config, removed in
                   if case .googleDocs(let cfg) = config { return cfg.accountEmail == removed.id }
                   return false
               })
    }

    func upsertMarkdownTarget(_ target: MarkdownTarget) {
        upsert(target, in: \.markdownTargets, key: Self.markdownTargetsKey,
               notification: .destinationsChanged)
    }
    func removeMarkdownTarget(id: String) {
        // Match by folder path against THIS specific target only — counting
        // how many other targets still claim the same path avoids cascading
        // bindings that belong to a sibling target.
        let removedPath = markdownTargets.first(where: { $0.id == id })?.folderPath
        remove(id: id, from: \.markdownTargets, key: Self.markdownTargetsKey,
               notification: .destinationsChanged,
               bindingMatches: { [weak self] config, _ in
                   guard case .markdownFolder(let cfg) = config,
                         let removedPath, cfg.folderPath == removedPath else { return false }
                   // Only cascade if no surviving target claims that path.
                   let othersAtSamePath = (self?.markdownTargets ?? []).contains { $0.folderPath == removedPath }
                   return !othersAtSamePath
               })
    }

    func upsertAppleNotesTarget(_ target: AppleNotesTarget) {
        upsert(target, in: \.appleNotesTargets, key: Self.appleNotesTargetsKey,
               notification: .destinationsChanged)
    }
    func removeAppleNotesTarget(id: String) {
        let removedFolder = appleNotesTargets.first(where: { $0.id == id })?.folderName
        remove(id: id, from: \.appleNotesTargets, key: Self.appleNotesTargetsKey,
               notification: .destinationsChanged,
               bindingMatches: { [weak self] config, _ in
                   guard case .appleNotes(let cfg) = config,
                         let removedFolder, cfg.folderName == removedFolder else { return false }
                   let othersClaimingFolder = (self?.appleNotesTargets ?? []).contains { $0.folderName == removedFolder }
                   return !othersClaimingFolder
               })
    }

    // MARK: Generic collection helpers

    /// Inserts or replaces an element in one of the published collections by id,
    /// persists it, and posts the matching notification.
    private func upsert<T: Identifiable & Codable & Equatable>(
        _ value: T,
        in keyPath: ReferenceWritableKeyPath<Ledger, [T]>,
        key: String,
        notification: Notification.Name
    ) where T.ID: Equatable {
        if let index = self[keyPath: keyPath].firstIndex(where: { $0.id == value.id }) {
            guard self[keyPath: keyPath][index] != value else { return }
            self[keyPath: keyPath][index] = value
        } else {
            self[keyPath: keyPath].append(value)
        }
        persist(value: self[keyPath: keyPath], key: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// Removes an element by id, cascades to any rule's destination bindings
    /// whose configuration matches the predicate, persists, and posts notifications.
    /// The predicate receives the just-removed element so callers can compare
    /// against its now-detached fields (folderPath, accountEmail, etc.).
    private func remove<T: Identifiable & Codable & Equatable>(
        id: T.ID,
        from keyPath: ReferenceWritableKeyPath<Ledger, [T]>,
        key: String,
        notification: Notification.Name,
        bindingMatches: (DestinationConfiguration, T) -> Bool
    ) where T.ID: Equatable {
        guard let removedIndex = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
        let removed = self[keyPath: keyPath].remove(at: removedIndex)
        var cascaded = false
        var removedBindingIds: Set<String> = []
        for ruleIndex in rules.indices {
            let before = rules[ruleIndex].destinations
            rules[ruleIndex].destinations.removeAll { bindingMatches($0.configuration, removed) }
            if rules[ruleIndex].destinations.count != before.count {
                cascaded = true
                let surviving = Set(rules[ruleIndex].destinations.map(\.id))
                removedBindingIds.formUnion(before.map(\.id).filter { !surviving.contains($0) })
            }
        }
        forgetSyncedHashes(forBindingIds: removedBindingIds)
        persist(value: self[keyPath: keyPath], key: key)
        if cascaded { persistRules() }
        NotificationCenter.default.post(name: notification, object: nil)
        if cascaded { NotificationCenter.default.post(name: .rulesChanged, object: nil) }
    }


    func upsertRule(_ rule: SyncRule) {
        var copy = rule
        copy.updatedAt = Date()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = copy
        } else {
            rules.append(copy)
        }
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func deleteRule(id: String) {
        let removedBindingIds = Set(rules.first(where: { $0.id == id })?.destinations.map(\.id) ?? [])
        rules.removeAll { $0.id == id }
        forgetSyncedHashes(forBindingIds: removedBindingIds)
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func rule(forNotebookId notebookId: String) -> SyncRule? {
        rules.first { $0.rmNotebookId == notebookId }
    }

    /// Drops rules whose folder is no longer present (e.g. orphaned by the
    /// folder/file model change or a deleted folder). Only call with a fully
    /// loaded, non-empty folder list so a transient fetch can't wipe rules.
    func pruneRules(keepingFolderIds folderIds: Set<String>) {
        let orphaned = rules.filter { !folderIds.contains($0.rmNotebookId) }
        guard !orphaned.isEmpty else { return }
        for rule in orphaned { deleteRule(id: rule.id) }
        Log.ledger.info("Pruned \(orphaned.count, privacy: .public) orphaned rule(s)")
    }

    // MARK: Rename helpers (header drawer entry points)

    func renameNotionWorkspace(id: String, newName: String) {
        guard var workspace = notionWorkspaces.first(where: { $0.id == id }) else { return }
        workspace.workspaceName = newName
        upsertNotionWorkspace(workspace)
    }

    func renameLinearAccount(id: String, newName: String) {
        guard var account = linearAccounts.first(where: { $0.id == id }) else { return }
        account.name = newName
        upsertLinearAccount(account)
        // Keep binding-level workspaceName cached labels in sync.
        for ruleIndex in rules.indices {
            for bindingIndex in rules[ruleIndex].destinations.indices {
                if case .linear(var cfg) = rules[ruleIndex].destinations[bindingIndex].configuration,
                   cfg.workspaceId == id {
                    cfg.workspaceName = newName
                    rules[ruleIndex].destinations[bindingIndex].configuration = .linear(cfg)
                }
            }
        }
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func renameGoogleAccount(id: String, newName: String) {
        guard var account = googleAccounts.first(where: { $0.id == id }) else { return }
        account.displayName = newName
        upsertGoogleAccount(account)
    }

    /// Pairs of (rule, binding) where the binding points at the given
    /// destination predicate. Used by the per-destination "Active syncs"
    /// list to enumerate which folders fan out to this destination.
    func bindings(matching predicate: (DestinationConfiguration) -> Bool) -> [(SyncRule, DestinationBinding)] {
        var output: [(SyncRule, DestinationBinding)] = []
        for rule in rules {
            for binding in rule.destinations where predicate(binding.configuration) {
                output.append((rule, binding))
            }
        }
        return output
    }

    /// Mutates a single destination binding's run state. The rule-level
    /// aggregates are derived properties so they need no separate update.
    func updateBindingRunResult(ruleId: String,
                                bindingId: String,
                                status: RuleRunStatus,
                                pagesSynced: Int,
                                runAt: Date,
                                error: String? = nil) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }),
              let bindingIndex = rules[ruleIndex].destinations.firstIndex(where: { $0.id == bindingId }) else { return }
        var binding = rules[ruleIndex].destinations[bindingIndex]
        let unchanged = binding.lastRunStatus == status
            && binding.lastRunPagesSynced == pagesSynced
            && binding.lastRunAt == runAt
            && binding.lastRunError == error
        guard !unchanged else { return }
        binding.lastRunStatus = status
        binding.lastRunPagesSynced = pagesSynced
        binding.lastRunAt = runAt
        binding.lastRunError = error
        rules[ruleIndex].destinations[bindingIndex] = binding
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    // MARK: Sync idempotency

    /// The version hash last synced for this page on this binding, if any.
    /// A match against `RmPage.versionHash` means the page is unchanged and
    /// can be skipped this cycle.
    func syncedHash(bindingId: String, pageId: String) -> String? {
        syncedPageHashes[Self.syncedHashKey(bindingId: bindingId, pageId: pageId)]
    }

    /// The external destination id of the note last written for this binding+file,
    /// if any, so the destination client can update it in place.
    func syncedExternalId(bindingId: String, pageId: String) -> String? {
        syncedExternalIds[Self.syncedHashKey(bindingId: bindingId, pageId: pageId)]
    }

    /// Records that `pageId` synced to `bindingId` at `versionHash`, along with
    /// the destination note's external id, so future cycles skip it until its
    /// content changes and can update the same note in place when it does.
    func recordSyncedPage(bindingId: String, pageId: String, versionHash: String, externalId: String?) {
        let key = Self.syncedHashKey(bindingId: bindingId, pageId: pageId)
        var changed = false
        if syncedPageHashes[key] != versionHash {
            syncedPageHashes[key] = versionHash
            changed = true
        }
        if let externalId, !externalId.isEmpty, syncedExternalIds[key] != externalId {
            syncedExternalIds[key] = externalId
            persistSyncedExternalIds()
        }
        if changed { persistSyncedHashes() }
    }

    /// Wipes the entire sync-tracking database (every recorded page hash and
    /// external id) so the next cycle resyncs all notes to all destinations.
    /// Does not touch the visible event log.
    func resetSyncDatabase() {
        guard !syncedPageHashes.isEmpty || !syncedExternalIds.isEmpty else { return }
        syncedPageHashes = [:]
        syncedExternalIds = [:]
        persistSyncedHashes()
        persistSyncedExternalIds()
    }

    /// Drops every page hash and external id recorded for the given bindings.
    /// Called when a binding is removed or re-pointed at a new destination so the
    /// next cycle resyncs into the new target rather than treating it as already
    /// done (or updating a note in the old target).
    private func forgetSyncedHashes(forBindingIds bindingIds: Set<String>) {
        guard !bindingIds.isEmpty else { return }
        let prefixes = bindingIds.map { "\($0)|" }
        let hashesBefore = syncedPageHashes.count
        syncedPageHashes = syncedPageHashes.filter { entry in
            !prefixes.contains { entry.key.hasPrefix($0) }
        }
        if syncedPageHashes.count != hashesBefore { persistSyncedHashes() }

        let idsBefore = syncedExternalIds.count
        syncedExternalIds = syncedExternalIds.filter { entry in
            !prefixes.contains { entry.key.hasPrefix($0) }
        }
        if syncedExternalIds.count != idsBefore { persistSyncedExternalIds() }
    }

    private static func syncedHashKey(bindingId: String, pageId: String) -> String {
        "\(bindingId)|\(pageId)"
    }

    func addBinding(ruleId: String, binding: DestinationBinding) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }) else { return }
        rules[ruleIndex].destinations.append(binding)
        rules[ruleIndex].updatedAt = Date()
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    /// Destination-first connect: finds or creates the folder's rule and attaches
    /// a destination binding, skipping an exact duplicate. This is the mirror of
    /// attaching a destination from the folder's rule sheet, so the source-first
    /// and destination-first flows converge on the same rule.
    func connect(folder: RmFolder, configuration: DestinationConfiguration) {
        if let existing = rule(forNotebookId: folder.id) {
            guard !existing.destinations.contains(where: { $0.configuration == configuration }) else { return }
            addBinding(ruleId: existing.id, binding: DestinationBinding(configuration: configuration))
        } else {
            var new = SyncRule.new(notebookId: folder.id, notebookName: folder.name)
            new.destinations = [DestinationBinding(configuration: configuration)]
            upsertRule(new)
        }
    }

    func updateBinding(ruleId: String, binding: DestinationBinding) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }),
              let bindingIndex = rules[ruleIndex].destinations.firstIndex(where: { $0.id == binding.id }) else { return }
        let previousConfiguration = rules[ruleIndex].destinations[bindingIndex].configuration
        rules[ruleIndex].destinations[bindingIndex] = binding
        rules[ruleIndex].updatedAt = Date()
        // Re-pointing the binding at a new destination invalidates its synced
        // history; pages must land in the new target on the next cycle.
        if previousConfiguration != binding.configuration {
            forgetSyncedHashes(forBindingIds: [binding.id])
        }
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func removeBinding(ruleId: String, bindingId: String) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }) else { return }
        rules[ruleIndex].destinations.removeAll { $0.id == bindingId }
        rules[ruleIndex].updatedAt = Date()
        forgetSyncedHashes(forBindingIds: [bindingId])
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func appendEvent(_ event: SyncEvent) {
        events.insert(event, at: 0)
        if events.count > Self.maxEventsRetained {
            events = Array(events.prefix(Self.maxEventsRetained))
        }
        persistEvents()
        NotificationCenter.default.post(name: .eventsChanged, object: nil)
    }

    func clearEvents() {
        events = []
        persistEvents()
        NotificationCenter.default.post(name: .eventsChanged, object: nil)
    }

    func setFolders(_ folders: [RmFolder]) {
        guard self.folders != folders else { return }
        self.folders = folders
        persistFolders()
        NotificationCenter.default.post(name: .foldersChanged, object: nil)
    }

    func exportSnapshot() -> Data? {
        struct Snapshot: Codable {
            let exportedAt: Date
            let remarkableAccount: RemarkableAccount?
            let notionWorkspaces: [NotionWorkspace]
            let linearAccounts: [LinearAccount]
            let googleAccounts: [GoogleAccount]
            let markdownTargets: [MarkdownTarget]
            let appleNotesTargets: [AppleNotesTarget]
            let rules: [SyncRule]
            let events: [SyncEvent]
            let folders: [RmFolder]
        }
        let snapshot = Snapshot(
            exportedAt: Date(),
            remarkableAccount: remarkableAccount,
            notionWorkspaces: notionWorkspaces,
            linearAccounts: linearAccounts,
            googleAccounts: googleAccounts,
            markdownTargets: markdownTargets,
            appleNotesTargets: appleNotesTargets,
            rules: rules,
            events: events,
            folders: folders
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    // MARK: Persistence

    private func load() {
        let defaults = store
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: Self.remarkableAccountKey) {
            remarkableAccount = try? decoder.decode(RemarkableAccount.self, from: data)
        }
        notionWorkspaces  = decodeArray([NotionWorkspace].self, key: Self.notionWorkspacesKey, defaults: defaults, decoder: decoder)
        linearAccounts    = decodeArray([LinearAccount].self,   key: Self.linearAccountsKey,   defaults: defaults, decoder: decoder)
        googleAccounts    = decodeArray([GoogleAccount].self,   key: Self.googleAccountsKey,   defaults: defaults, decoder: decoder)
        markdownTargets   = decodeArray([MarkdownTarget].self,  key: Self.markdownTargetsKey,  defaults: defaults, decoder: decoder)
        appleNotesTargets = decodeArray([AppleNotesTarget].self, key: Self.appleNotesTargetsKey, defaults: defaults, decoder: decoder)
        rules             = decodeArray([SyncRule].self,        key: Self.rulesKey,            defaults: defaults, decoder: decoder)
        events            = decodeArray([SyncEvent].self,       key: Self.eventsKey,           defaults: defaults, decoder: decoder)
        folders         = decodeArray([RmFolder].self,      key: Self.foldersKey,        defaults: defaults, decoder: decoder)

        if let data = defaults.data(forKey: Self.syncedPageHashesKey),
           let value = try? decoder.decode([String: String].self, from: data) {
            syncedPageHashes = value
        }
        if let data = defaults.data(forKey: Self.syncedExternalIdsKey),
           let value = try? decoder.decode([String: String].self, from: data) {
            syncedExternalIds = value
        }

        stripLeakedTestData(defaults: defaults)
    }

    /// One-time cleanup of placeholder "Test" rules and events that earlier
    /// XCTest runs leaked into the real UserDefaults before test persistence
    /// was isolated (the debounced delete at each test's end was cut short by
    /// process exit, so the upserted rule survived). Runs once.
    private func stripLeakedTestData(defaults: UserDefaults) {
        let flag = "ledger.didStripTestPollution.v1"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let cleanedRules = rules.filter { $0.rmNotebookName != "Test" }
        if cleanedRules.count != rules.count {
            rules = cleanedRules
            persistRules()
        }
        let cleanedEvents = events.filter { $0.rmNotebookName != "Test" }
        if cleanedEvents.count != events.count {
            events = cleanedEvents
            persistEvents()
        }
    }

    private func decodeArray<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults, decoder: JSONDecoder) -> T where T: ExpressibleByArrayLiteral {
        guard let data = defaults.data(forKey: key),
              let value = try? decoder.decode(T.self, from: data) else {
            return []
        }
        return value
    }

    /// Synchronous encode-and-write. Used for one-off writes where we want
    /// the snapshot on disk before returning (e.g. account changes the user
    /// just confirmed).
    fileprivate func persist<T: Encodable>(value: T, key: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return }
        store.set(data, forKey: key)
    }

    /// Coalesces high-frequency writes (events, rule run-status updates) so
    /// we don't re-encode the whole array on every mutation inside a sync
    /// cycle. Always reads the live array at the time the debounce fires so
    /// callers can mutate in quick succession without losing intermediate
    /// state.
    fileprivate func persistDebounced<T: Encodable>(_ snapshot: @escaping () -> T, key: String) {
        pendingPersistTasks[key]?.cancel()
        pendingPersistTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceMs)
            guard !Task.isCancelled, let self else { return }
            let value = snapshot()
            self.persist(value: value, key: key)
            self.pendingPersistTasks[key] = nil
        }
    }

    private func persistRemarkable()    { persist(value: remarkableAccount, key: Self.remarkableAccountKey) }
    private func persistRules()         { persistDebounced({ [weak self] in self?.rules ?? [] }, key: Self.rulesKey) }
    private func persistEvents()        { persistDebounced({ [weak self] in self?.events ?? [] }, key: Self.eventsKey) }
    private func persistFolders()     { persist(value: folders, key: Self.foldersKey) }
    private func persistSyncedHashes()  { persistDebounced({ [weak self] in self?.syncedPageHashes ?? [:] }, key: Self.syncedPageHashesKey) }
    private func persistSyncedExternalIds() { persistDebounced({ [weak self] in self?.syncedExternalIds ?? [:] }, key: Self.syncedExternalIdsKey) }
}
