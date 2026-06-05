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
    case chrome

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notion:         return "Notion"
        case .linear:         return "Linear"
        case .googleDocs:     return "Google Docs"
        case .appleNotes:     return "Apple Notes"
        case .markdownFolder: return "Markdown files"
        case .chrome:         return "Chrome"
        }
    }

    var sidebarSubtitle: String {
        switch self {
        case .notion:         return "Pages and databases"
        case .linear:         return "Issues and projects"
        case .googleDocs:     return "Google Drive documents"
        case .appleNotes:     return "iCloud Notes"
        case .markdownFolder: return "Local folder"
        case .chrome:         return "Browser bookmarks"
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
        case .chrome:         return "globe"
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
        case .chrome:         return "Destinations/Chrome"
        }
    }

    /// Whether the destination needs OAuth/setup to be usable. Apple Notes
    /// and Markdown work out of the box on the user's machine.
    var requiresExternalAccount: Bool {
        switch self {
        case .notion, .linear, .googleDocs:         return true
        case .appleNotes, .markdownFolder, .chrome: return false
        }
    }

    /// Whether the bundled brand mark is a single-color silhouette that must be
    /// tinted to the foreground to stay visible across light and dark themes.
    /// The Linear mark ships as solid white and would vanish on light themes;
    /// full-color marks (Google, Apple Notes) and the two-tone Notion mark read
    /// correctly on both, so they render in their own colors.
    var brandMarkIsMonochrome: Bool {
        switch self {
        case .linear, .markdownFolder:                   return true
        case .notion, .googleDocs, .appleNotes, .chrome: return false
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

struct ChromeDestinationConfig: Codable, Equatable, Hashable {
    var profileDirName: String      // Chrome profile directory, e.g. "Default"
    var targetFolderPath: [String]  // Chrome folder to write into, e.g. ["Bookmarks Bar", "From Safari"]
}

// MARK: - Polymorphic configuration

enum DestinationConfiguration: Codable, Equatable, Hashable {
    case notion(NotionDestinationConfig)
    case linear(LinearDestinationConfig)
    case googleDocs(GoogleDocsDestinationConfig)
    case appleNotes(AppleNotesDestinationConfig)
    case markdownFolder(MarkdownFolderDestinationConfig)
    case chrome(ChromeDestinationConfig)

    var kind: DestinationKind {
        switch self {
        case .notion:         return .notion
        case .linear:         return .linear
        case .googleDocs:     return .googleDocs
        case .appleNotes:     return .appleNotes
        case .markdownFolder: return .markdownFolder
        case .chrome:         return .chrome
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
        case .chrome(let config):         return config.targetFolderPath.last ?? "Chrome"
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
    /// Only sync reMarkable notes carrying at least one of these tags (OR
    /// semantics). nil/empty means sync every note. Applies to any destination.
    var requiredTags: [String]?

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         configuration: DestinationConfiguration,
         createdAt: Date = Date(),
         lastRunAt: Date? = nil,
         lastRunStatus: RuleRunStatus = .neverRun,
         lastRunPagesSynced: Int = 0,
         lastRunError: String? = nil,
         ocrModeOverride: OcrMode? = nil,
         titleStrategyOverride: TitleStrategy? = nil,
         requiredTags: [String]? = nil) {
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
        self.requiredTags = requiredTags
    }

    /// The active tag filter, preferring the per-binding value and falling back
    /// to Linear's legacy per-config field so existing filters keep working
    /// without a migration.
    var effectiveRequiredTags: [String]? {
        if let requiredTags, !requiredTags.isEmpty { return requiredTags }
        if case .linear(let cfg) = configuration { return cfg.requiredTags }
        return nil
    }

    /// Whether a note carrying these tags should sync here. No filter (or an
    /// empty one) accepts every note; otherwise the note must carry at least one
    /// required tag.
    func accepts(fileTags: [String]) -> Bool {
        guard let required = effectiveRequiredTags, !required.isEmpty else { return true }
        return !Set(required).isDisjoint(with: Set(fileTags))
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

/// A local Markdown destination: a folder plus the default write settings every
/// connection to it inherits (and may override per connection). The folder is
/// chosen when the destination is created, so a connection never starts blank.
struct MarkdownTarget: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var folderPath: String
    var connectedAt: Date
    /// Default file-name template. Optional so targets persisted before this
    /// field existed still decode (missing key -> the standard default below).
    var fileNameTemplate: String? = nil
    /// Default "include YAML frontmatter" setting, optional for the same reason.
    var includeFrontmatter: Bool? = nil

    static let defaultFileNameTemplate = "{notebook}-page-{page_n}"

    /// The full configuration a new connection to this destination inherits.
    var defaultConfiguration: MarkdownFolderDestinationConfig {
        MarkdownFolderDestinationConfig(
            folderPath: folderPath,
            fileNameTemplate: fileNameTemplate ?? Self.defaultFileNameTemplate,
            includeFrontmatter: includeFrontmatter ?? true
        )
    }
}

/// Apple Notes target. There's no "account" per se - the user is whoever's
/// signed in to iCloud Notes - but we model a row so the sidebar can list it.
struct AppleNotesTarget: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var folderName: String
    var connectedAt: Date
}

/// A connected Google Chrome profile to write bookmarks into. Like Markdown and
/// Apple Notes it's a marker — the target folder is chosen per sync.
struct ChromeTarget: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var profileDirName: String      // "Default"
    var connectedAt: Date
}

// MARK: - Default configuration for a connected destination
//
// The configuration a new connection inherits, shared by both the source-first
// flow (the folder's rule sheet) and the destination-first flow (connect a
// folder from the destination's detail view) so the two never drift. OAuth
// destinations start at a sensible default the user refines per connection.
// (MarkdownTarget defines its own `defaultConfiguration` above.)

extension NotionWorkspace {
    var defaultConfiguration: DestinationConfiguration {
        .notion(NotionDestinationConfig(
            workspaceId: id, destinationId: "", destinationType: .page,
            destinationTitle: workspaceName, propertyMappings: [:]))
    }
}

extension LinearAccount {
    var defaultConfiguration: DestinationConfiguration {
        .linear(LinearDestinationConfig(
            workspaceId: id, workspaceName: name, projectId: nil,
            projectName: nil, defaultLabel: nil, requiredTags: nil))
    }
}

extension GoogleAccount {
    var defaultConfiguration: DestinationConfiguration {
        .googleDocs(GoogleDocsDestinationConfig(
            accountEmail: id, folderId: nil, folderName: nil, appendMode: .onePerPage))
    }
}

extension AppleNotesTarget {
    var defaultConfiguration: DestinationConfiguration {
        .appleNotes(AppleNotesDestinationConfig(folderName: folderName))
    }
}

extension ChromeTarget {
    var defaultConfiguration: DestinationConfiguration {
        .chrome(ChromeDestinationConfig(profileDirName: profileDirName, targetFolderPath: ["Bookmarks Bar"]))
    }
}
