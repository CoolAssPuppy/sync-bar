//
//  Destinations.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// One of the supported destination kinds. Every binding on a rule belongs
/// to exactly one. Adding a new destination type means:
///   1. Add a case here.
///   2. Add a `DestinationConfiguration` case with its config payload.
///   3. Implement a `DestinationClient` for it.
///   4. Add a right-pane detail view + an "Add" sheet for the sidebar.
enum DestinationKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case notion
    case linear
    case googleDocs
    case appleNotes
    case markdownFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notion:         return "Notion"
        case .linear:         return "Linear"
        case .googleDocs:     return "Google Docs"
        case .appleNotes:     return "Apple Notes"
        case .markdownFolder: return "Markdown files"
        }
    }

    var sidebarSubtitle: String {
        switch self {
        case .notion:         return "Pages and databases"
        case .linear:         return "Issues and projects"
        case .googleDocs:     return "Google Drive documents"
        case .appleNotes:     return "iCloud Notes"
        case .markdownFolder: return "Local folder"
        }
    }

    /// SF Symbol used in the sidebar and the destination picker.
    var systemImage: String {
        switch self {
        case .notion:         return "square.grid.3x3.fill"
        case .linear:         return "triangle.fill"
        case .googleDocs:     return "doc.text.fill"
        case .appleNotes:     return "note.text"
        case .markdownFolder: return "folder.fill"
        }
    }

    /// Whether the destination needs OAuth/setup to be usable. Apple Notes
    /// and Markdown work out of the box on the user's machine.
    var requiresExternalAccount: Bool {
        switch self {
        case .notion, .linear, .googleDocs: return true
        case .appleNotes, .markdownFolder:  return false
        }
    }
}

// MARK: - Per-destination configuration payloads

struct NotionDestinationConfig: Codable, Equatable, Hashable {
    var workspaceId: String
    var destinationId: String
    var destinationType: NotionDestinationType  // page or database
    var destinationTitle: String
}

struct LinearDestinationConfig: Codable, Equatable, Hashable {
    var workspaceId: String        // Linear team ID
    var workspaceName: String
    var projectId: String?
    var projectName: String?
    var defaultLabel: String?
}

struct GoogleDocsDestinationConfig: Codable, Equatable, Hashable {
    var accountEmail: String
    var folderId: String?
    var folderName: String?
    /// Append mode: create a fresh doc per page, or append to a single doc.
    var appendMode: AppendMode

    enum AppendMode: String, Codable, CaseIterable, Identifiable {
        case onePerPage
        case appendToSingleDoc

        var id: String { rawValue }
        var label: String {
            switch self {
            case .onePerPage:        return "One doc per page"
            case .appendToSingleDoc: return "Append to a single doc"
            }
        }
    }
}

struct AppleNotesDestinationConfig: Codable, Equatable, Hashable {
    var folderName: String          // e.g. "Notes", "Work", "Travel"
}

struct MarkdownFolderDestinationConfig: Codable, Equatable, Hashable {
    var folderPath: String          // Absolute file URL path
    var fileNameTemplate: String    // e.g. "{notebook}-{page_n}-{date}"
    var includeFrontmatter: Bool
}

// MARK: - Polymorphic configuration

enum DestinationConfiguration: Codable, Equatable, Hashable {
    case notion(NotionDestinationConfig)
    case linear(LinearDestinationConfig)
    case googleDocs(GoogleDocsDestinationConfig)
    case appleNotes(AppleNotesDestinationConfig)
    case markdownFolder(MarkdownFolderDestinationConfig)

    var kind: DestinationKind {
        switch self {
        case .notion:         return .notion
        case .linear:         return .linear
        case .googleDocs:     return .googleDocs
        case .appleNotes:     return .appleNotes
        case .markdownFolder: return .markdownFolder
        }
    }

    /// One-line description shown in rules sheet rows and the menu bar popover.
    var summary: String {
        switch self {
        case .notion(let config):         return config.destinationTitle
        case .linear(let config):         return [config.workspaceName, config.projectName].compactMap { $0 }.joined(separator: " · ")
        case .googleDocs(let config):     return [config.folderName, config.accountEmail].compactMap { $0 }.joined(separator: " · ")
        case .appleNotes(let config):     return config.folderName
        case .markdownFolder(let config): return (config.folderPath as NSString).lastPathComponent
        }
    }
}

// MARK: - Binding (one destination on one rule)

struct DestinationBinding: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var enabled: Bool
    var kind: DestinationKind { configuration.kind }
    var configuration: DestinationConfiguration
    var createdAt: Date
    var lastRunAt: Date?
    var lastRunStatus: RuleRunStatus
    var lastRunPagesSynced: Int
    var lastRunError: String?
    /// Optional override of the rule-level OCR mode for this destination only.
    var ocrModeOverride: OcrMode?
    /// Optional override of the rule-level title strategy for this destination.
    var titleStrategyOverride: TitleStrategy?

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         configuration: DestinationConfiguration,
         createdAt: Date = Date(),
         lastRunAt: Date? = nil,
         lastRunStatus: RuleRunStatus = .neverRun,
         lastRunPagesSynced: Int = 0,
         lastRunError: String? = nil,
         ocrModeOverride: OcrMode? = nil,
         titleStrategyOverride: TitleStrategy? = nil) {
        self.id = id
        self.enabled = enabled
        self.configuration = configuration
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.lastRunPagesSynced = lastRunPagesSynced
        self.lastRunError = lastRunError
        self.ocrModeOverride = ocrModeOverride
        self.titleStrategyOverride = titleStrategyOverride
    }
}

// MARK: - Account records for non-Notion destinations

/// One Linear team the user has authorized.
struct LinearAccount: Codable, Equatable, Identifiable, Hashable {
    var id: String              // team ID
    var name: String            // team name
    var organizationName: String
    var connectedAt: Date
}

/// One Google account the user has authorized.
struct GoogleAccount: Codable, Equatable, Identifiable, Hashable {
    var id: String              // email
    var displayName: String
    var connectedAt: Date
}

/// Local Markdown sync target.
struct MarkdownTarget: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var folderPath: String
    var connectedAt: Date
}

/// Apple Notes target. There's no "account" per se - the user is whoever's
/// signed in to iCloud Notes - but we model a row so the sidebar can list it.
struct AppleNotesTarget: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var folderName: String
    var connectedAt: Date
}
