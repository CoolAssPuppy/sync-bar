//
//  Destinations.swift
//  SyncBar
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

    /// SF Symbol used as a fallback when the bundled brand asset is missing.
    var systemImage: String {
        switch self {
        case .notion:         return "square.grid.3x3.fill"
        case .linear:         return "triangle.fill"
        case .googleDocs:     return "doc.text.fill"
        case .appleNotes:     return "note.text"
        case .markdownFolder: return "folder.fill"
        }
    }

    /// Name of the brand asset shipped in `Images.xcassets/Destinations/`.
    /// Asset slots ship with placeholder marks until the real brand artwork
    /// drops in; we still render the SF Symbol if the asset is missing.
    var assetName: String {
        switch self {
        case .notion:         return "Destinations/Notion"
        case .linear:         return "Destinations/Linear"
        case .googleDocs:     return "Destinations/GoogleDocs"
        case .appleNotes:     return "Destinations/AppleNotes"
        case .markdownFolder: return "Destinations/Markdown"
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

    /// Whether the bundled brand mark is a single-color silhouette that must be
    /// tinted to the foreground to stay visible across light and dark themes.
    /// The Linear mark ships as solid white and would vanish on light themes;
    /// full-color marks (Google, Apple Notes) and the two-tone Notion mark read
    /// correctly on both, so they render in their own colors.
    var brandMarkIsMonochrome: Bool {
        switch self {
        case .linear, .markdownFolder:        return true
        case .notion, .googleDocs, .appleNotes: return false
        }
    }
}

// MARK: - Per-destination configuration payloads

struct NotionDestinationConfig: Codable, Equatable, Hashable {
    var workspaceId: String
    var destinationId: String
    var destinationType: NotionDestinationType  // page or database
    var destinationTitle: String
    /// Per-property mappings for database destinations. Keyed by Notion
    /// property name. Empty when the destination is a page or the user
    /// hasn't customized any column yet.
    var propertyMappings: [String: NotionPropertyMapping] = [:]
}

/// What to write into a single Notion database column when a page syncs.
/// One case per Notion property type we know how to populate.
enum NotionPropertyMapping: Codable, Equatable, Hashable {
    /// Skip the column. Notion stores it as empty.
    case leaveBlank
    /// Plain text or rich text with token substitution.
    case text(template: String)
    /// A single Notion option name (select / status).
    case selectOption(String)
    /// Zero or more option names (multi_select).
    case multiSelectOptions([String])
    /// A literal date source instead of a free-form date.
    case dateSource(DateSource)
    /// A boolean checkbox value.
    case checkbox(Bool)
    /// A literal numeric value.
    case number(Double)
    /// A free-form URL, email, or phone-number string.
    case literal(String)

    enum DateSource: String, Codable, CaseIterable, Identifiable {
        case pageCreated
        case pageModified
        case syncedAt

        var id: String { rawValue }
        var label: String {
            switch self {
            case .pageCreated:  return "Page created date"
            case .pageModified: return "Page modified date"
            case .syncedAt:     return "Sync date"
            }
        }
    }
}

struct LinearDestinationConfig: Codable, Equatable, Hashable {
    var workspaceId: String        // Linear team ID
    var workspaceName: String
    var projectId: String?
    var projectName: String?
    var defaultLabel: String?
    /// When non-empty, only reMarkable notes carrying at least one of these
    /// document tags are synced to this destination. Empty/nil means sync all.
    var requiredTags: [String]?
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

    /// Whether a note carrying these document tags should sync to this
    /// destination. Only Linear honors a tag filter today: a note is accepted
    /// when it has at least one of the configured `requiredTags` (OR semantics).
    /// Every other destination, and Linear with no filter, accepts all notes.
    func accepts(fileTags: [String]) -> Bool {
        guard case .linear(let config) = self,
              let required = config.requiredTags, !required.isEmpty else { return true }
        return !Set(required).isDisjoint(with: Set(fileTags))
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
