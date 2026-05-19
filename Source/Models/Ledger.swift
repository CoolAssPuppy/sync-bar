//
//  Ledger.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Combine

/// In-memory + UserDefaults-backed ledger of accounts, rules, and sync events.
///
/// The spec calls for CloudKit private database storage. For the overnight
/// build we model the API surface the rest of the app needs and back it with
/// UserDefaults so the app works end-to-end on a single machine. Swapping in a
/// CloudKit implementation later only touches this file.
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
    private static let notebooksKey         = "ledger.notebooks"

    @Published private(set) var remarkableAccount: RemarkableAccount?
    @Published private(set) var notionWorkspaces: [NotionWorkspace] = []
    @Published private(set) var linearAccounts: [LinearAccount] = []
    @Published private(set) var googleAccounts: [GoogleAccount] = []
    @Published private(set) var markdownTargets: [MarkdownTarget] = []
    @Published private(set) var appleNotesTargets: [AppleNotesTarget] = []
    @Published private(set) var rules: [SyncRule] = []
    @Published private(set) var events: [SyncEvent] = []
    @Published private(set) var notebooks: [RmNotebook] = []

    private static let maxEventsRetained = 500
    private static let persistDebounceMs: UInt64 = 250_000_000  // 250 ms
    private var pendingPersistTasks: [String: Task<Void, Never>] = [:]

    private init() {
        load()
    }

    deinit {
        pendingPersistTasks.values.forEach { $0.cancel() }
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
        remove(id: id, from: \.markdownTargets, key: Self.markdownTargetsKey,
               notification: .destinationsChanged,
               bindingMatches: { config, removed in
                   if case .markdownFolder(let cfg) = config { return cfg.folderPath == removed.folderPath }
                   return false
               })
    }

    func upsertAppleNotesTarget(_ target: AppleNotesTarget) {
        upsert(target, in: \.appleNotesTargets, key: Self.appleNotesTargetsKey,
               notification: .destinationsChanged)
    }
    func removeAppleNotesTarget(id: String) {
        remove(id: id, from: \.appleNotesTargets, key: Self.appleNotesTargetsKey,
               notification: .destinationsChanged,
               bindingMatches: { config, removed in
                   if case .appleNotes(let cfg) = config { return cfg.folderName == removed.folderName }
                   return false
               })
    }

    // MARK: Generic collection helpers

    /// Inserts or replaces an element in one of the published collections by id,
    /// persists it, and posts the matching notification.
    private func upsert<T: Identifiable & Codable>(
        _ value: T,
        in keyPath: ReferenceWritableKeyPath<Ledger, [T]>,
        key: String,
        notification: Notification.Name
    ) where T.ID: Equatable {
        if let index = self[keyPath: keyPath].firstIndex(where: { $0.id == value.id }) {
            guard !areEqualEncoded(self[keyPath: keyPath][index], value) else { return }
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
    private func remove<T: Identifiable & Codable>(
        id: T.ID,
        from keyPath: ReferenceWritableKeyPath<Ledger, [T]>,
        key: String,
        notification: Notification.Name,
        bindingMatches: (DestinationConfiguration, T) -> Bool
    ) where T.ID: Equatable {
        guard let removedIndex = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
        let removed = self[keyPath: keyPath].remove(at: removedIndex)
        var cascaded = false
        for ruleIndex in rules.indices {
            let before = rules[ruleIndex].destinations.count
            rules[ruleIndex].destinations.removeAll { bindingMatches($0.configuration, removed) }
            if rules[ruleIndex].destinations.count != before { cascaded = true }
        }
        persist(value: self[keyPath: keyPath], key: key)
        if cascaded { persistRules() }
        NotificationCenter.default.post(name: notification, object: nil)
        if cascaded { NotificationCenter.default.post(name: .rulesChanged, object: nil) }
    }

    /// Best-effort no-op detector by re-encoding both sides. Cheaper than
    /// requiring Equatable on every type in the ledger.
    private func areEqualEncoded<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder()
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else { return false }
        return lhsData == rhsData
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
        rules.removeAll { $0.id == id }
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func rule(forNotebookId notebookId: String) -> SyncRule? {
        rules.first { $0.rmNotebookId == notebookId }
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

    func addBinding(ruleId: String, binding: DestinationBinding) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }) else { return }
        rules[ruleIndex].destinations.append(binding)
        rules[ruleIndex].updatedAt = Date()
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func updateBinding(ruleId: String, binding: DestinationBinding) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }),
              let bindingIndex = rules[ruleIndex].destinations.firstIndex(where: { $0.id == binding.id }) else { return }
        rules[ruleIndex].destinations[bindingIndex] = binding
        rules[ruleIndex].updatedAt = Date()
        persistRules()
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func removeBinding(ruleId: String, bindingId: String) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleId }) else { return }
        rules[ruleIndex].destinations.removeAll { $0.id == bindingId }
        rules[ruleIndex].updatedAt = Date()
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

    func setNotebooks(_ notebooks: [RmNotebook]) {
        guard self.notebooks != notebooks else { return }
        self.notebooks = notebooks
        persistNotebooks()
        NotificationCenter.default.post(name: .notebooksChanged, object: nil)
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
            let notebooks: [RmNotebook]
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
            notebooks: notebooks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    // MARK: Persistence

    private func load() {
        let defaults = UserDefaults.standard
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
        notebooks         = decodeArray([RmNotebook].self,      key: Self.notebooksKey,        defaults: defaults, decoder: decoder)
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
        UserDefaults.standard.set(data, forKey: key)
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

    private func persistRemarkable() { persist(value: remarkableAccount, key: Self.remarkableAccountKey) }
    private func persistWorkspaces() { persist(value: notionWorkspaces,  key: Self.notionWorkspacesKey)  }
    private func persistRules()      { persistDebounced({ [weak self] in self?.rules ?? [] }, key: Self.rulesKey) }
    private func persistEvents()     { persistDebounced({ [weak self] in self?.events ?? [] }, key: Self.eventsKey) }
    private func persistNotebooks()  { persist(value: notebooks, key: Self.notebooksKey) }
}
