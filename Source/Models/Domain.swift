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

struct RmNotebook: Codable, Equatable, Identifiable, Hashable {
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

// MARK: - Sync rule

enum TitleStrategy: String, Codable, CaseIterable, Identifiable {
    case firstLineOfOcr
    case template
    case pageNumber
    case rmCreatedDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .firstLineOfOcr: return "First line of OCR"
        case .template:       return "Template"
        case .pageNumber:     return "Page number"
        case .rmCreatedDate:  return "reMarkable date"
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

/// A sync rule binds one reMarkable notebook to zero or more destinations.
/// Adding the first destination turns the rule "active"; removing all of
/// them leaves the rule as a saved shell the user can re-attach later.
struct SyncRule: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var enabled: Bool
    var rmNotebookId: String
    var rmNotebookName: String
    var titleStrategy: TitleStrategy
    var titleTemplate: String?
    var pageOrder: PageOrder
    var ocrMode: OcrMode
    var ocrProviderOverride: OcrProviderChoice?
    var savePdfAttachment: Bool
    var createdAt: Date
    var updatedAt: Date
    var destinations: [DestinationBinding]

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

    var label: String {
        switch self {
        case .pageSynced:        return "Page synced"
        case .pageFailed:        return "Page failed"
        case .ruleRunStarted:    return "Run started"
        case .ruleRunCompleted:  return "Run completed"
        case .tokenRefreshed:    return "Token refreshed"
        case .orphanDetected:    return "Orphan detected"
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
