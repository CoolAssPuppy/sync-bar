//
//  NotionMarkdownPreview.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Read-only dry run for a Notion -> Markdown sync. Reads the Notion database and
//  the existing `.md` files in the target folder, matches by `notion_id`
//  (frontmatter), and reports what a first run would do: which files it would
//  create (new pages), which existing files it would keep/adopt, and which `.md`
//  files have no matching Notion page (kept, never deleted). Writes a report file
//  and nothing else.
//

import Foundation

enum NotionMarkdownPreview {

    static func generate(source: NotionSourceConfig,
                         config: MarkdownFolderDestinationConfig,
                         keychain: KeychainStore = .shared,
                         now: Date = Date()) async throws -> URL {
        let items = try await NotionSourceClient(keychain: keychain).listItems(config: .notion(source))
        let index = MarkdownAdoptionIndex.read(folderPath: config.folderPath)   // notion_id -> path
        let knownIds = Set(items.map(\.id))

        var fresh: [(item: SourceItem, path: String)] = []
        var keptCount = 0
        let template = config.fileNameTemplate.isEmpty ? "{date}-{title}" : config.fileNameTemplate
        for item in items {
            if index[item.id] != nil { keptCount += 1; continue }
            let payload = DestinationPayload(
                title: item.name, body: "", mermaidSource: nil, sourceDate: item.createdAt,
                ruleNotebookName: item.name, pageNumber: 1, folderPath: item.folderPath, sourceId: item.id)
            fresh.append((item, MarkdownDestinationClient.resolveRelativePath(template: template, payload: payload)))
        }
        let orphanFiles = index.filter { !knownIds.contains($0.key) }.map(\.value).sorted()

        let markdown = render(databaseTitle: source.databaseTitle.isEmpty ? "Notion" : source.databaseTitle,
                              folder: config.folderPath, pageCount: items.count,
                              fresh: fresh, keptCount: keptCount, orphanFiles: orphanFiles, now: now)
        let url = try reportURL(databaseTitle: source.databaseTitle)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Render (pure)

    static func render(databaseTitle: String, folder: String, pageCount: Int,
                       fresh: [(item: SourceItem, path: String)], keptCount: Int,
                       orphanFiles: [String], now: Date) -> String {
        var out = ""
        out += "# SyncBar dry run — \(databaseTitle) → Markdown\n\n"
        out += "_Generated \(timestamp(now)). **Nothing was written.** Previews a first run into "
        out += "`\(folder.isEmpty ? "(no folder chosen)" : folder)`. Existing files are matched by "
        out += "`notion_id` and kept as-is; only new pages create files._\n\n"

        out += "## Summary\n\n"
        out += "- Pages in Notion: **\(pageCount)**\n"
        out += "- Would **create** new files: **\(fresh.count)**\n"
        out += "- Existing files **kept as-is** (matched by notion_id): **\(keptCount)**\n"
        out += "- `.md` files with **no Notion page** (kept, never deleted): **\(orphanFiles.count)**\n\n"

        // By folder (the leading Category component of each new file's path).
        var byFolder: [String: Int] = [:]
        for entry in fresh {
            let folderPart = entry.path.contains("/") ? String(entry.path.prefix(upTo: entry.path.firstIndex(of: "/")!)) : "(root)"
            byFolder[folderPart, default: 0] += 1
        }
        if !byFolder.isEmpty {
            out += "## New files by folder\n\n| Folder | Create |\n|---|---:|\n"
            for key in byFolder.keys.sorted(by: { byFolder[$0]! > byFolder[$1]! }) {
                out += "| \(key) | \(byFolder[key]!) |\n"
            }
            out += "\n"
        }

        out += section(title: "Would create (\(fresh.count))",
                       empty: "Nothing new to create.",
                       lines: fresh.sorted { $0.path < $1.path }.map { "- \($0.path)" })
        out += section(title: "Orphan files — no matching Notion page (\(orphanFiles.count))",
                       empty: "Every file matches a current Notion page.",
                       lines: orphanFiles.map { "- \(($0 as NSString).lastPathComponent)" },
                       note: "Left in place (a deleted/archived Notion page, or a file from another tool).")
        return out
    }

    private static let maxListed = 200

    private static func section(title: String, empty: String, lines: [String], note: String? = nil) -> String {
        var out = "## \(title)\n\n"
        if let note { out += "_\(note)_\n\n" }
        if lines.isEmpty { return out + "_\(empty)_\n\n" }
        out += lines.prefix(maxListed).joined(separator: "\n") + "\n"
        if lines.count > maxListed { out += "\n_… and \(lines.count - maxListed) more._\n" }
        return out + "\n"
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: date)
    }

    private static func reportURL(databaseTitle: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SyncBar", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = databaseTitle.isEmpty ? "Notion"
            : databaseTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return base.appendingPathComponent("Dry run — \(safe) (Markdown).md")
    }
}
