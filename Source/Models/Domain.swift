//
//  Domain.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

// MARK: - reMarkable

struct RemarkableAccount: Codable, Equatable {
    var pairedAt: Date
    var userIdentifier: String
    var lastSyncedAt: Date?
}

/// A reMarkable folder. This is the unit a sync rule targets today: every
/// `RmFile` document inside the folder is synced together. The synthetic
/// "Unfiled" folder (`unfiledFolderId`) groups root-level documents.
/// Note: `pageCount` here is the number of documents in the folder, not pages.
struct RmFolder: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var parentFolder: String?
    var lastModified: Date
    var pageCount: Int
}

struct RmPage: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { "\(notebookId)-\(pageId)" }
    var notebookId: String
    var pageId: String
    var positionInNotebook: Int
    var createdAt: Date
    var modifiedAt: Date
    var hasTypedText: Bool
    var versionHash: String
}

/// A reMarkable document (a "notebook" file) inside a folder. In Sync Bar's
/// model a folder is the rule target and each file in it becomes one note: all
/// of the file's pages are transcribed and combined into a single destination
/// entry. `versionHash` is the document's content hash, used for idempotency.
struct RmFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var folderId: String
    var createdAt: Date
    var lastModified: Date
    var pageCount: Int
    var versionHash: String
    /// Document-level reMarkable tags on this note, used for per-destination
    /// tag filtering. Empty when untagged.
    var tags: [String] = []
}

/// Sentinel folder id for files that live at the cloud root (no folder).
let unfiledFolderId = "__unfiled__"

/// The outcome of uploading one file to the reMarkable cloud.
struct RmUploadResult: Sendable, Equatable {
    var documentId: String
    var visibleName: String
}

// MARK: - Notion

struct NotionWorkspace: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var workspaceName: String
    var workspaceIcon: String?
    var botId: String
    var connectedAt: Date
    var lastCatalogRefreshAt: Date?
}

enum NotionDestinationType: String, Codable {
    case page
    case database
}

struct NotionDestination: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var type: NotionDestinationType
    var title: String
    var icon: String?
    var parentPath: String?
}

struct NotionDatabaseProperty: Codable, Equatable, Hashable {
    var name: String
    var type: String
    var options: [String]
}

// MARK: - X (Twitter)

/// One connected X account. The id is the X user id (also the keychain token
/// key and the `/2/users/{id}/…` path segment). `selectedStreams` records which
/// content types the user opted into at connect time — only those have the OAuth
/// scopes required to read them, so the sync editor offers exactly these.
struct XAccount: Codable, Equatable, Identifiable, Hashable {
    var id: String              // X user id
    var username: String        // @handle, without the leading @
    var displayName: String
    var connectedAt: Date
    var selectedStreams: [XStream]

    /// The handle shown in the UI, with the conventional leading @.
    var handle: String { username.hasPrefix("@") ? username : "@\(username)" }

    // Tolerant decoder so an account persisted before `selectedStreams` existed
    // still loads (defaulting to all three streams rather than dropping the row).
    init(id: String, username: String, displayName: String, connectedAt: Date,
         selectedStreams: [XStream] = XStream.allCases) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.connectedAt = connectedAt
        self.selectedStreams = selectedStreams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        displayName = try c.decode(String.self, forKey: .displayName)
        connectedAt = try c.decode(Date.self, forKey: .connectedAt)
        selectedStreams = try c.decodeIfPresent([XStream].self, forKey: .selectedStreams) ?? XStream.allCases
    }
}

// MARK: - Sync rule

enum TitleStrategy: String, Codable, CaseIterable, Identifiable {
    case fileName
    case firstLineOfOcr
    case template

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fileName:       return "File name"
        case .firstLineOfOcr: return "First line of OCR"
        case .template:       return "Template"
        }
    }
}

enum PageOrder: String, Codable, CaseIterable, Identifiable {
    case chronological
    case reverseChronological

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chronological:        return "Chronological"
        case .reverseChronological: return "Reverse chronological"
        }
    }
}

enum OcrMode: String, Codable, CaseIterable, Identifiable {
    case all
    case handwrittenOnly
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:             return "All pages"
        case .handwrittenOnly: return "Handwritten only"
        case .none:            return "None"
        }
    }
}

enum OcrProviderChoice: String, Codable, CaseIterable, Identifiable {
    case vision
    case openai
    case anthropic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vision:    return "Apple Vision"
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }
}

/// A sync rule binds one source (a reMarkable folder today) to zero or more
/// destinations. Adding the first destination turns the rule "active"; removing
/// all of them leaves the rule as a saved shell the user can re-attach later.
/// The source half is polymorphic (`SourceConfiguration`), mirroring how
/// destinations are modeled, so new source kinds drop in without reshaping the
/// rule.
struct SyncRule: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var enabled: Bool
    var source: SourceConfiguration
    var createdAt: Date
    var updatedAt: Date
    var destinations: [DestinationBinding]

    /// Generic source accessors, preferred going forward over the reMarkable
    /// passthroughs below.
    var sourceKind: SourceKind { source.kind }
    var sourceSummary: String { source.summary }

    // MARK: Generic init

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         source: SourceConfiguration,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         destinations: [DestinationBinding] = []) {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.destinations = destinations
    }

    // MARK: reMarkable source access
    //
    // reMarkable is the only source today, and its editor/catalog code needs its
    // typed fields. They're reached explicitly through the source case rather than
    // projected onto SyncRule, so a future non-reMarkable rule can never read a
    // misleading reMarkable default — exactly how destinations unwrap their config.

    /// The reMarkable configuration when this rule's source is reMarkable.
    var remarkableConfig: RemarkableSourceConfig? {
        if case .remarkable(let config) = source { return config }
        return nil
    }

    /// Mutates the reMarkable configuration in place. A no-op for other sources.
    mutating func updateRemarkable(_ transform: (inout RemarkableSourceConfig) -> Void) {
        guard case .remarkable(var config) = source else { return }
        transform(&config)
        source = .remarkable(config)
    }

    /// Old-style memberwise initializer, kept so reMarkable construction sites
    /// (DemoData, `new(notebookId:notebookName:)`) build a `.remarkable` source
    /// without change. Transitional, alongside the passthroughs above.
    init(id: String, enabled: Bool,
         rmNotebookId: String, rmNotebookName: String,
         selectedFileIds: [String]? = nil,
         titleStrategy: TitleStrategy, titleTemplate: String?,
         pageOrder: PageOrder, ocrMode: OcrMode,
         ocrProviderOverride: OcrProviderChoice?, savePdfAttachment: Bool,
         createdAt: Date, updatedAt: Date, destinations: [DestinationBinding]) {
        self.id = id
        self.enabled = enabled
        self.source = .remarkable(RemarkableSourceConfig(
            folderId: rmNotebookId, folderName: rmNotebookName, selectedFileIds: selectedFileIds,
            titleStrategy: titleStrategy, titleTemplate: titleTemplate, pageOrder: pageOrder,
            ocrMode: ocrMode, ocrProviderOverride: ocrProviderOverride, savePdfAttachment: savePdfAttachment))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.destinations = destinations
    }

    static func new(notebookId: String, notebookName: String) -> SyncRule {
        let now = Date()
        return SyncRule(
            id: UUID().uuidString,
            enabled: true,
            rmNotebookId: notebookId,
            rmNotebookName: notebookName,
            titleStrategy: .firstLineOfOcr,
            titleTemplate: nil,
            pageOrder: .chronological,
            ocrMode: .all,
            ocrProviderOverride: nil,
            savePdfAttachment: true,
            createdAt: now,
            updatedAt: now,
            destinations: []
        )
    }

    /// Build a new rule targeting a source scope. The generic entry point the
    /// "Choose a Source" flow uses; reMarkable is the only kind today.
    static func new(scope: SourceScope) -> SyncRule {
        new(notebookId: scope.id, notebookName: scope.name)
    }

    /// Whether this rule syncs every item in the scope (vs a hand-picked set).
    var syncsEntireFolder: Bool {
        (remarkableConfig?.selectedFileIds ?? []).isEmpty
    }

    /// Whether a given item is in this rule's scope. The whole scope is in scope
    /// when no specific items are selected.
    func includes(itemId: String) -> Bool {
        guard let ids = remarkableConfig?.selectedFileIds, !ids.isEmpty else { return true }
        return ids.contains(itemId)
    }

    /// Aggregated rollup across all destination bindings on this rule.
    var aggregateLastRunAt: Date? {
        destinations.compactMap(\.lastRunAt).max()
    }

    var aggregateLastRunPagesSynced: Int {
        destinations.map(\.lastRunPagesSynced).reduce(0, +)
    }

    var aggregateLastRunStatus: RuleRunStatus {
        guard !destinations.isEmpty else { return .neverRun }
        let statuses = destinations.map(\.lastRunStatus)
        if statuses.contains(.running)    { return .running }
        if statuses.contains(.error)      { return .error }
        if statuses.contains(.partial)    { return .partial }
        if statuses.allSatisfy({ $0 == .success }) { return .success }
        return .neverRun
    }
}

enum RuleRunStatus: String, Codable {
    case neverRun
    case success
    case partial
    case error
    case running

    var label: String {
        switch self {
        case .neverRun: return "Never run"
        case .success:  return "Synced"
        case .partial:  return "Partial"
        case .error:    return "Failed"
        case .running:  return "Running"
        }
    }
}

// MARK: - Sync event

enum SyncEventType: String, Codable {
    case pageSynced
    case pageFailed
    case ruleRunStarted
    case ruleRunCompleted
    case tokenRefreshed
    case orphanDetected
    /// A manual sync that found no work, written so "Sync now" never silently
    /// does nothing. Carries the human-readable reason in the event.
    case cycleSkipped

    var label: String {
        switch self {
        case .pageSynced:        return "Page synced"
        case .pageFailed:        return "Page failed"
        case .ruleRunStarted:    return "Run started"
        case .ruleRunCompleted:  return "Run completed"
        case .tokenRefreshed:    return "Token refreshed"
        case .orphanDetected:    return "Orphan detected"
        case .cycleSkipped:      return "Nothing to sync"
        }
    }
}

struct SyncEvent: Codable, Equatable, Identifiable {
    var id: String
    var occurredAt: Date
    var ruleId: String?
    var ruleName: String?
    var eventType: SyncEventType
    var rmNotebookName: String?
    var rmPageId: String?
    var notionPageUrl: String?
    var durationMs: Int?
    var ocrProvider: String?
    var errorMessage: String?
}
