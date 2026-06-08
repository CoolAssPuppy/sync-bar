//
//  NotionAppleNotesPreview.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Read-only dry run for a Notion -> Apple Notes sync. Reads the Notion database
//  and the local Apple Notes account, runs the same adoption matcher the real
//  sync uses, renders a Markdown report (NoteSyncPreview), and writes it to a
//  file the caller can open. Writes a report file and nothing else — it never
//  touches Notion or Apple Notes content. Assumes a first run (ignores any prior
//  ledger state), which is the worst case the user wants to inspect.
//

import Foundation

enum NotionAppleNotesPreview {

    /// Generates the dry-run report file and returns its URL. `fallbackNotebook`
    /// is where uncategorized pages would land (the Apple Notes destination's
    /// configured folder, or "Notes").
    static func generate(source: NotionSourceConfig,
                         fallbackNotebook: String,
                         keychain: KeychainStore = .shared,
                         now: Date = Date()) async throws -> URL {
        let client = NotionSourceClient(keychain: keychain)
        let items = try await client.listItems(config: .notion(source))
        let candidates = items.map { item in
            AdoptionCandidate(notionId: item.id,
                              title: item.name,
                              category: item.folderPath.last,
                              createdAt: item.createdAt)
        }
        let apple = try await AppleNotesInventory.read()
        let result = NoteAdoptionMatcher.match(notion: candidates, apple: apple)
        let markdown = NoteSyncPreview.renderMarkdown(
            candidates: candidates, apple: apple, result: result,
            fallbackNotebook: fallbackNotebook,
            databaseTitle: source.databaseTitle.isEmpty ? "Notion" : source.databaseTitle,
            now: now)

        let url = try reportURL(databaseTitle: source.databaseTitle)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `~/Library/Application Support/SyncBar/Dry run — <database>.md`, overwritten
    /// each run so the latest preview is always at a predictable path.
    private static func reportURL(databaseTitle: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SyncBar", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = databaseTitle.isEmpty ? "Notion"
            : databaseTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return base.appendingPathComponent("Dry run — \(safe).md")
    }
}
