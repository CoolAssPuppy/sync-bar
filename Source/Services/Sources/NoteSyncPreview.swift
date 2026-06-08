//
//  NoteSyncPreview.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Renders a dry-run report for a Notion -> Apple Notes sync: given the Notion
//  pages, the existing Apple notes, and the adoption match, it describes exactly
//  what a first run would do — which pages get created, which get updated in
//  place (Notion content overwriting a matched note), and which Apple notes have
//  no Notion counterpart (orphans). Pure and deterministic; the caller reads the
//  live data and writes/opens the file. Nothing here writes anything.
//

import Foundation

enum NoteSyncPreview {

    /// Counts a UI can show without parsing the report text.
    struct Counts: Equatable {
        var pages: Int
        var create: Int
        var adopt: Int
        var orphans: Int
    }

    static func counts(result: AdoptionResult, pageCount: Int) -> Counts {
        Counts(pages: pageCount,
               create: result.freshNotionIds.count,
               adopt: result.links.count,
               orphans: result.orphanAppleNoteIds.count)
    }

    /// At most this many entries are listed per detailed section; counts stay
    /// exact. Keeps a 3,000-page database's report readable.
    private static let maxListed = 200

    static func renderMarkdown(candidates: [AdoptionCandidate],
                               apple: [ExistingAppleNote],
                               result: AdoptionResult,
                               fallbackNotebook: String,
                               databaseTitle: String,
                               now: Date) -> String {
        let candById = Dictionary(candidates.map { ($0.notionId, $0) }, uniquingKeysWith: { a, _ in a })
        let noteById = Dictionary(apple.map { ($0.noteId, $0) }, uniquingKeysWith: { a, _ in a })
        let c = counts(result: result, pageCount: candidates.count)

        func notebook(for category: String?) -> String {
            guard let category, !category.isEmpty else { return fallbackNotebook }
            return category
        }
        func notebookLabel(for category: String?) -> String {
            guard let category, !category.isEmpty else { return "(uncategorized → \(fallbackNotebook))" }
            return category
        }

        var out = ""
        out += "# SyncBar dry run — \(databaseTitle)\n\n"
        out += "_Generated \(timestamp(now)). **Nothing was written.** This previews a first run "
        out += "(Notion → Apple Notes), where Notion is the source of truth._\n\n"

        out += "## Summary\n\n"
        out += "- Pages in Notion: **\(c.pages)**\n"
        out += "- Would **create** new notes: **\(c.create)**\n"
        out += "- Would **update in place** (matched an existing note; Notion content wins): **\(c.adopt)**\n"
        out += "- Apple notes with **no Notion match** (orphans, would upload to Notion later): **\(c.orphans)**\n\n"

        // By notebook: create + update tallies.
        var createByNb: [String: Int] = [:]
        var adoptByNb: [String: Int] = [:]
        for id in result.freshNotionIds {
            createByNb[notebookLabel(for: candById[id]?.category), default: 0] += 1
        }
        for link in result.links {
            adoptByNb[notebookLabel(for: candById[link.notionId]?.category), default: 0] += 1
        }
        let notebooks = Set(createByNb.keys).union(adoptByNb.keys).sorted {
            (createByNb[$0, default: 0] + adoptByNb[$0, default: 0]) > (createByNb[$1, default: 0] + adoptByNb[$1, default: 0])
        }
        if !notebooks.isEmpty {
            out += "## By notebook\n\n"
            out += "| Notebook | Create | Update |\n|---|---:|---:|\n"
            for nb in notebooks {
                out += "| \(nb) | \(createByNb[nb, default: 0]) | \(adoptByNb[nb, default: 0]) |\n"
            }
            out += "\n"
        }

        // Detailed: create.
        let creates = result.freshNotionIds.compactMap { candById[$0] }
            .sorted { ($0.category ?? "", $0.title) < ($1.category ?? "", $1.title) }
        out += section(title: "Would create (\(creates.count))",
                       empty: "Nothing new to create.",
                       lines: creates.map { "- [\(notebook(for: $0.category))] \($0.title)" })

        // Detailed: update in place.
        let adopts: [(cand: AdoptionCandidate, note: ExistingAppleNote)] = result.links.compactMap { link in
            guard let cand = candById[link.notionId], let note = noteById[link.appleNoteId] else { return nil }
            return (cand, note)
        }.sorted { ($0.cand.category ?? "", $0.cand.title) < ($1.cand.category ?? "", $1.cand.title) }
        out += section(title: "Would update in place (\(adopts.count))",
                       empty: "No existing notes matched.",
                       lines: adopts.map { "- [\(notebook(for: $0.cand.category))] \($0.cand.title)  ←  existing note “\($0.note.title)”" })

        // Detailed: orphans.
        let orphans = result.orphanAppleNoteIds.compactMap { noteById[$0] }
            .sorted { ($0.notebook, $0.title) < ($1.notebook, $1.title) }
        out += section(title: "Orphans — Apple notes with no Notion page (\(orphans.count))",
                       empty: "Every Apple note in these notebooks has a Notion page.",
                       lines: orphans.map { "- [\($0.notebook)] \($0.title)" },
                       note: "These would be candidates for Apple → Notion upload (not built yet).")

        return out
    }

    // MARK: Helpers

    private static func section(title: String, empty: String, lines: [String], note: String? = nil) -> String {
        var out = "## \(title)\n\n"
        if let note { out += "_\(note)_\n\n" }
        if lines.isEmpty {
            out += "_\(empty)_\n\n"
            return out
        }
        out += lines.prefix(maxListed).joined(separator: "\n")
        out += "\n"
        if lines.count > maxListed {
            out += "\n_… and \(lines.count - maxListed) more._\n"
        }
        out += "\n"
        return out
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
