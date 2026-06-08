//
//  MarkdownAdoptionIndex.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  First-run adoption for Notion -> Markdown. Unlike Apple Notes (which strips
//  hidden markers, forcing a title+date match), a Markdown file carries its
//  `notion_id` in frontmatter — so adoption is an exact id match. This scans a
//  folder's `.md` files, reads each one's `notion_id`, and returns the map the
//  coordinator uses to link existing files (kept as-is) instead of duplicating
//  them. Reads only the frontmatter block of each file, not the whole body.
//

import Foundation

enum MarkdownAdoptionIndex {

    /// `notion_id` -> file path for every `.md` under `folderPath` that carries
    /// one. When a notion_id appears in several files (the Python backup made
    /// duplicates), the most recently modified file wins, so the canonical copy is
    /// the one kept in sync.
    static func read(folderPath: String) -> [String: String] {
        let base = URL(fileURLWithPath: folderPath, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [:] }
        var index: [String: String] = [:]
        var mtimeOfChosen: [String: Date] = [:]
        for case let url as URL in enumerator where url.pathExtension == "md" {
            guard let id = notionId(ofFileAt: url) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let existing = mtimeOfChosen[id], existing >= mtime { continue }
            index[id] = url.path
            mtimeOfChosen[id] = mtime
        }
        return index
    }

    /// Reads `notion_id` from a file's leading frontmatter without loading the
    /// whole file. Returns nil when there's no frontmatter or no id.
    static func notionId(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return parseNotionId(frontmatter: head)
    }

    /// Extracts `notion_id` from a YAML frontmatter block at the start of `text`.
    /// The block must open with `---` on the first line; scanning stops at the
    /// closing `---`. Tolerates quoting and surrounding whitespace.
    static func parseNotionId(frontmatter text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil }   // end of frontmatter, not found
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            guard key == "notion_id" else { continue }
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
