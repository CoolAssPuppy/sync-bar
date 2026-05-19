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

    private init() {
        load()
    }

    // MARK: Public API

    func setRemarkableAccount(_ account: RemarkableAccount?) {
        remarkableAccount = account
        persistRemarkable()
        NotificationCenter.default.post(name: .remarkableAccountChanged, object: nil)
    }

    func upsertNotionWorkspace(_ workspace: NotionWorkspace) {
        if let index = notionWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
            notionWorkspaces[index] = workspace
        } else {
            notionWorkspaces.append(workspace)
        }
        persistWorkspaces()
        NotificationCenter.default.post(name: .notionWorkspacesChanged, object: nil)
    }

    func removeNotionWorkspace(id: String) {
        notionWorkspaces.removeAll { $0.id == id }
        for index in rules.indices {
            rules[index].destinations.removeAll { binding in
                if case .notion(let cfg) = binding.configuration, cfg.workspaceId == id { return true }
                return false
            }
        }
        persistWorkspaces()
        persistRules()
        NotificationCenter.default.post(name: .notionWorkspacesChanged, object: nil)
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func upsertLinearAccount(_ account: LinearAccount) {
        if let index = linearAccounts.firstIndex(where: { $0.id == account.id }) {
            linearAccounts[index] = account
        } else {
            linearAccounts.append(account)
        }
        persist(value: linearAccounts, key: Self.linearAccountsKey)
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
    }

    func removeLinearAccount(id: String) {
        linearAccounts.removeAll { $0.id == id }
        for index in rules.indices {
            rules[index].destinations.removeAll { binding in
                if case .linear(let cfg) = binding.configuration, cfg.workspaceId == id { return true }
                return false
            }
        }
        persist(value: linearAccounts, key: Self.linearAccountsKey)
        persistRules()
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func upsertGoogleAccount(_ account: GoogleAccount) {
        if let index = googleAccounts.firstIndex(where: { $0.id == account.id }) {
            googleAccounts[index] = account
        } else {
            googleAccounts.append(account)
        }
        persist(value: googleAccounts, key: Self.googleAccountsKey)
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
    }

    func removeGoogleAccount(id: String) {
        googleAccounts.removeAll { $0.id == id }
        for index in rules.indices {
            rules[index].destinations.removeAll { binding in
                if case .googleDocs(let cfg) = binding.configuration, cfg.accountEmail == id { return true }
                return false
            }
        }
        persist(value: googleAccounts, key: Self.googleAccountsKey)
        persistRules()
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
        NotificationCenter.default.post(name: .rulesChanged, object: nil)
    }

    func upsertMarkdownTarget(_ target: MarkdownTarget) {
        if let index = markdownTargets.firstIndex(where: { $0.id == target.id }) {
            markdownTargets[index] = target
        } else {
            markdownTargets.append(target)
        }
        persist(value: markdownTargets, key: Self.markdownTargetsKey)
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
    }

    func removeMarkdownTarget(id: String) {
        markdownTargets.removeAll { $0.id == id }
        persist(value: markdownTargets, key: Self.markdownTargetsKey)
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
    }

    func upsertAppleNotesTarget(_ target: AppleNotesTarget) {
        if let index = appleNotesTargets.firstIndex(where: { $0.id == target.id }) {
            appleNotesTargets[index] = target
        } else {
            appleNotesTargets.append(target)
        }
        persist(value: appleNotesTargets, key: Self.appleNotesTargetsKey)
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
    }

    func removeAppleNotesTarget(id: String) {
        appleNotesTargets.removeAll { $0.id == id }
        persist(value: appleNotesTargets, key: Self.appleNotesTargetsKey)
        NotificationCenter.default.post(name: .destinationsChanged, object: nil)
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
        rules[ruleIndex].destinations[bindingIndex].lastRunStatus = status
        rules[ruleIndex].destinations[bindingIndex].lastRunPagesSynced = pagesSynced
        rules[ruleIndex].destinations[bindingIndex].lastRunAt = runAt
        rules[ruleIndex].destinations[bindingIndex].lastRunError = error
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

    fileprivate func persist<T: Encodable>(value: T, key: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistRemarkable() { persist(value: remarkableAccount, key: Self.remarkableAccountKey) }
    private func persistWorkspaces() { persist(value: notionWorkspaces,  key: Self.notionWorkspacesKey)  }
    private func persistRules()      { persist(value: rules,             key: Self.rulesKey)             }
    private func persistEvents()     { persist(value: events,            key: Self.eventsKey)            }
    private func persistNotebooks()  { persist(value: notebooks,         key: Self.notebooksKey)         }
}
