//
//  DestinationClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// One page-worth of content ready to write to a destination. Filled by
/// the rules engine after OCR has resolved.
struct DestinationPayload: Sendable {
    var title: String
    var body: String              // already includes ```mermaid block if any
    var mermaidSource: String?    // also passed separately for destinations
                                  // that want first-class diagram support
    var sourceDate: Date
    var pdfData: Data?            // optional attachment when rule.savePdfAttachment is on
    var ocrProvider: String?
    var ruleNotebookName: String
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
