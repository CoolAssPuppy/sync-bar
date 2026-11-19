//
//  NotionSourcePreview.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Runs the read-only dry run for a Notion source and returns the report's URL.
enum NotionSourcePreview {
    static func generate(destination: DestinationKind?, source: NotionSourceConfig,
                         markdown: MarkdownFolderDestinationConfig, fallbackNotebook: String) async throws -> URL {
        switch destination {
        case .markdownFolder:
            return try await NotionMarkdownPreview.generate(source: source, config: markdown)
        default:
            return try await NotionAppleNotesPreview.generate(source: source, fallbackNotebook: fallbackNotebook)
        }
    }
}
