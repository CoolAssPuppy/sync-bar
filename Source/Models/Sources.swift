//
//  Sources.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A source is a place Sync Bar pulls notes FROM. reMarkable is the only one
//  today, but the kind is modeled separately from the data layer so adding a
//  new source is a matter of a new case plus its brand mark - the UI already
//  renders any SourceKind through SourceIcon / SourceMark.
//

import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case remarkable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remarkable: return "reMarkable"
        }
    }

    /// One-line description for pickers and empty states.
    var subtitle: String {
        switch self {
        case .remarkable: return "Tablet notebooks and documents"
        }
    }

    /// SF Symbol fallback when the bundled brand asset is missing.
    var systemImage: String {
        switch self {
        case .remarkable: return "rectangle.portrait.on.rectangle.portrait"
        }
    }

    /// Brand asset shipped in `Images.xcassets`.
    var assetName: String {
        switch self {
        case .remarkable: return "Remarkable"
        }
    }

    /// Whether the brand mark is a single-color silhouette that must be tinted
    /// to stay visible across themes (see DestinationKind for the same idea).
    var brandMarkIsMonochrome: Bool {
        switch self {
        case .remarkable: return false
        }
    }
}

// MARK: - Per-source configuration payloads

/// reMarkable source settings: which folder (and optional sub-selection of
/// documents) to pull, plus the read/transcription knobs that used to live
/// directly on `SyncRule`. The folder is the scope a rule targets; each
/// document in it becomes one note.
struct RemarkableSourceConfig: Codable, Equatable, Hashable {
    var folderId: String              // was SyncRule.rmNotebookId
    var folderName: String            // was SyncRule.rmNotebookName
    /// Which documents in the folder to sync. `nil`/empty means the whole folder
    /// (current and future documents); a non-empty set scopes to those file ids.
    var selectedFileIds: [String]? = nil
    var titleStrategy: TitleStrategy
    var titleTemplate: String?
    var pageOrder: PageOrder
    var ocrMode: OcrMode
    var ocrProviderOverride: OcrProviderChoice?
    var savePdfAttachment: Bool
}

// MARK: - Polymorphic configuration

/// The source half of a sync, mirroring `DestinationConfiguration`. One case per
/// `SourceKind`. Adding a source means a new case here, a `SourceClient`, and a
/// `SourceRouter` branch — the destination quartet's exact shape.
enum SourceConfiguration: Codable, Equatable, Hashable {
    case remarkable(RemarkableSourceConfig)

    var kind: SourceKind {
        switch self {
        case .remarkable: return .remarkable
        }
    }

    /// One-line description shown in rule rows, the menu bar popover, and the
    /// activity log (replaces the old `rule.rmNotebookName` reads).
    var summary: String {
        switch self {
        case .remarkable(let config): return config.folderName
        }
    }
}

// MARK: - Scope

/// A targetable container within a source — a reMarkable folder today. Used by
/// the "Choose a Source" picker and the folder/notebook chooser. Generalizes
/// `RmFolder` for source-agnostic UI; `itemCount` is the number of syncable
/// items (documents) inside.
struct SourceScope: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var itemCount: Int
}
