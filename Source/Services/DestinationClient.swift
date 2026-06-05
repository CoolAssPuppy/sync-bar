//
//  DestinationClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// One note-worth of content ready to write to a destination — the combined
/// transcription of all the file's pages.
struct DestinationPayload: Sendable {
    var title: String
    var body: String              // markdown flattening of `blocks`, minus diagrams
    var blocks: [NoteBlock] = []  // structured content; destinations render this
                                  // natively (Notion to_do/heading, etc.) and
                                  // fall back to `body` when it's empty
    var mermaidSource: String?    // also passed separately for destinations
                                  // that want first-class diagram support
    var sourceDate: Date
    var pdfData: Data?            // optional attachment when rule.savePdfAttachment is on
    var ocrProvider: String?
    var ruleNotebookName: String  // the note (file) name
    var folderName: String = ""   // the containing folder (rule subject)
    var pageNumber: Int
    /// The source item's URL when it is a bookmark; nil for document sources.
    /// Browser-bookmark destinations write this; note destinations ignore it.
    var url: URL? = nil
    /// The folder path the item should mirror into at the destination (e.g.
    /// ["Bookmarks Bar", "Supabase"]). Browser-bookmark destinations honor this
    /// to recreate the source hierarchy; empty means "use the destination's
    /// configured target folder."
    var folderPath: [String] = []
}

/// Outcome of writing one page to one destination.
struct DestinationWriteResult: Sendable {
    var externalId: String?
    var externalURL: URL?
    var notes: String?
}

/// Outcome of a set-level reconcile (mirror). Counts what changed.
struct DestinationReconcileResult: Sendable {
    var added: Int = 0
    var updated: Int = 0
    var deleted: Int = 0
    var unchanged: Int = 0
}

protocol DestinationClient: Sendable {
    var kind: DestinationKind { get }
    /// Writes one note to the destination. When `existingExternalId` is non-nil,
    /// the note was synced before and should be updated in place (same Notion
    /// page, Google doc, Linear issue, Apple Notes note, or Markdown file) rather
    /// than created anew. Clients fall back to creating if the prior note is gone.
    func write(payload: DestinationPayload, configuration: DestinationConfiguration, existingExternalId: String?) async throws -> DestinationWriteResult

    /// Whether this destination should reconcile the full desired set (mirror,
    /// including deletes) for the given configuration, instead of per-item writes.
    func reconciles(_ configuration: DestinationConfiguration) -> Bool

    /// Makes the destination exactly match `desired` — add missing, update
    /// changed, delete extras (within the managed scope). Only called when
    /// `reconciles(_:)` is true.
    func reconcile(desired: [DestinationPayload], configuration: DestinationConfiguration) async throws -> DestinationReconcileResult
}

extension DestinationClient {
    func reconciles(_ configuration: DestinationConfiguration) -> Bool { false }
    func reconcile(desired: [DestinationPayload], configuration: DestinationConfiguration) async throws -> DestinationReconcileResult {
        throw DestinationError.scriptFailed("This destination doesn't support mirroring.")
    }
}

/// Errors raised by destination clients. Each case is destination-domain
/// (not OCR-domain) so user-facing messages stay accurate.
enum DestinationError: LocalizedError, Sendable {
    case wrongConfiguration(expected: DestinationKind)
    case scriptFailed(String)
    case apiFailed(status: Int, snippet: String)
    case rateLimited
    case fileSystem(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .wrongConfiguration(let expected):
            return "Destination configuration didn't match \(expected.label)."
        case .scriptFailed(let message):
            return message
        case .apiFailed(let status, let snippet):
            return "API call failed (HTTP \(status)): \(snippet)"
        case .rateLimited:
            return "The destination throttled us. Try again in a minute."
        case .fileSystem(let message):
            return message
        case .network(let message):
            return message
        }
    }
}

// MARK: - Routing

/// Single point that, given a binding, returns the right client. Keeping
/// this in one place means SyncCoordinator never branches on destination kind.
enum DestinationRouter {
    static func client(for kind: DestinationKind) -> DestinationClient {
        switch kind {
        case .notion:         return NotionDestinationClient()
        case .linear:         return LinearDestinationClient()
        case .googleDocs:     return GoogleDocsDestinationClient()
        case .appleNotes:     return AppleNotesDestinationClient()
        case .markdownFolder: return MarkdownDestinationClient()
        case .chrome:         return ChromeBookmarkDestinationClient()
        }
    }
}
