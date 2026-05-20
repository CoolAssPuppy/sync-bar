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
    var body: String              // already includes ```mermaid block if any
    var mermaidSource: String?    // also passed separately for destinations
                                  // that want first-class diagram support
    var sourceDate: Date
    var pdfData: Data?            // optional attachment when rule.savePdfAttachment is on
    var ocrProvider: String?
    var ruleNotebookName: String  // the note (file) name
    var folderName: String = ""   // the containing folder (rule subject)
    var pageNumber: Int
}

/// Outcome of writing one page to one destination.
struct DestinationWriteResult: Sendable {
    var externalId: String?
    var externalURL: URL?
    var notes: String?
}

protocol DestinationClient: Sendable {
    var kind: DestinationKind { get }
    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult
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
        }
    }
}
