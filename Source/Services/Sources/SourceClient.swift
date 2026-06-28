//
//  SourceClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// One syncable unit a source emits — a reMarkable document today, a browser
/// bookmark tomorrow. Carries the identity and version used for idempotency and
/// the tags used for per-destination filtering. The actual content (which may be
/// expensive to produce, e.g. OCR) is fetched separately via `content(for:)` so
/// it is computed once per item and reused across every destination binding.
struct SourceItem: Sendable, Equatable, Hashable {
    var id: String          // stable per-source id (reMarkable file id, Safari bookmark UUID)
    var name: String
    var versionHash: String // content hash: "changed since last sync?"
    var createdAt: Date
    var tags: [String] = []
    /// The item's URL, when it is one (a bookmark). nil for document sources.
    /// Carried through to `DestinationPayload.url` so URL-shaped destinations
    /// (browser bookmarks) have something to write.
    var url: URL? = nil
    /// The destination folder path this item should mirror into (a bookmark's
    /// folder hierarchy, e.g. ["Bookmarks Bar", "Supabase"]). Empty for sources
    /// with no hierarchy to preserve.
    var folderPath: [String] = []
    /// Source-provided key/value metadata (a Notion row's column values), carried
    /// to destinations that record it — e.g. Markdown frontmatter. Empty for
    /// sources without structured metadata.
    var metadata: [String: String] = [:]
}

/// Errors raised by source clients. Source-domain (not destination/OCR domain)
/// so user-facing messages stay accurate.
enum SourceError: LocalizedError, Sendable {
    case notConfigured
    case wrongConfiguration(expected: SourceKind)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This sync has no source configured."
        case .wrongConfiguration(let expected):
            return "Source configuration didn't match \(expected.label)."
        case .unavailable(let message):
            return message
        }
    }
}

/// The source half of the pipeline, mirroring `DestinationClient`. A source
/// lists the scopes a rule can target, lists the items in a configured scope,
/// renders one item to `NoteContent` (the neutral seam destinations consume),
/// and resolves a per-item title. Keeping the heavy `content(for:)` call
/// separate preserves the "render once, fan out to N destinations" win.
protocol SourceClient: Sendable {
    var kind: SourceKind { get }

    /// Scopes the user can target when creating a rule (reMarkable folders).
    func listScopes() async throws -> [SourceScope]

    /// Every item in the configured scope (the whole folder). Sub-selection
    /// (`selectedFileIds`) and tag filtering stay with the coordinator so it can
    /// still distinguish "folder empty" from "selected notes missing".
    func listItems(config: SourceConfiguration) async throws -> [SourceItem]

    /// Render one item to content, once, reused across destinations. Expensive
    /// work (OCR) lives here.
    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent

    /// The per-item title for the configured strategy. `strategyOverride` lets a
    /// destination binding override the rule-level strategy. Semantics are
    /// source-specific (file name / first OCR line / template).
    func resolveTitle(for item: SourceItem,
                      content: NoteContent,
                      config: SourceConfiguration,
                      strategyOverride: TitleStrategy?) -> String

    /// Whether an item that produced this content should be skipped as "empty".
    /// Source-specific: reMarkable suppresses only when OCR mode is "none" and the
    /// page is blank; sources without such a notion never suppress. `ocrModeOverride`
    /// is the destination binding's optional override of the rule-level OCR mode.
    func shouldSkipAsEmpty(content: NoteContent,
                           config: SourceConfiguration,
                           ocrModeOverride: OcrMode?) -> Bool
}

// MARK: - Routing

/// Single point that, given a kind, returns the right source client — the mirror
/// of `DestinationRouter`. Keeping it here means `SyncCoordinator` never branches
/// on source kind.
enum SourceRouter {
    static func client(for kind: SourceKind) -> SourceClient {
        switch kind {
        case .remarkable: return RemarkableSourceClient()
        case .safari:     return SafariSourceClient()
        case .notion:     return NotionSourceClient()
        case .x:          return XSourceClient()
        }
    }
}
