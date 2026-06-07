//
//  NoteAdoptionMatcher.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  First-run adoption: before the first Notion -> Apple Notes sync, decide which
//  Notion pages already exist as Apple notes (so the sync updates them in place
//  instead of duplicating) and which Apple notes have no Notion counterpart (so
//  they can be offered for upload). Identity can't live in the note body — Apple
//  Notes strips hidden markers — so it lives in the ledger, seeded by this match.
//  Pure and deterministic: I/O (reading Apple notes, seeding the ledger) is the
//  caller's job. Matching mirrors the validated Python analysis: normalized title
//  within the same notebook (= Category), creation date as the tiebreaker.
//

import Foundation

/// One Notion page that wants a home in Apple Notes.
struct AdoptionCandidate: Equatable {
    var notionId: String
    var title: String
    /// The Category value — the Apple Notes notebook this page belongs in. nil
    /// for uncategorized pages (which match only other uncategorized notes).
    var category: String?
    /// Notion's created_time, which preserves the original (pre-migration) note
    /// date — the tiebreaker when a notebook has two same-titled notes.
    var createdAt: Date
}

/// One existing Apple note, as read from the local Notes database.
struct ExistingAppleNote: Equatable {
    var noteId: String
    var notebook: String
    var title: String
    var createdAt: Date
}

struct AdoptionResult: Equatable {
    /// Notion page -> existing Apple note. Seed these into the ledger so the sync
    /// updates the note in place (Notion content wins) rather than creating a copy.
    var links: [(notionId: String, appleNoteId: String)]
    /// Notion pages with no Apple match — created fresh on the first sync.
    var freshNotionIds: [String]
    /// Apple notes (within the candidate notebooks) that no Notion page claimed —
    /// the orphan-upload candidates.
    var orphanAppleNoteIds: [String]

    static func == (lhs: AdoptionResult, rhs: AdoptionResult) -> Bool {
        lhs.freshNotionIds == rhs.freshNotionIds
            && lhs.orphanAppleNoteIds == rhs.orphanAppleNoteIds
            && lhs.links.count == rhs.links.count
            && zip(lhs.links, rhs.links).allSatisfy { $0.notionId == $1.notionId && $0.appleNoteId == $1.appleNoteId }
    }
}

enum NoteAdoptionMatcher {

    /// Pairs Notion pages with existing Apple notes. Each Apple note is claimed by
    /// at most one page (one-to-one), preferring a same-day creation date when a
    /// notebook holds several same-titled notes. Apple notes are only considered
    /// orphans within notebooks that correspond to a Notion category in the
    /// candidate set — notes in unrelated notebooks are ignored, not uploaded.
    static func match(notion: [AdoptionCandidate], apple: [ExistingAppleNote]) -> AdoptionResult {
        // Index Apple notes by notebook -> normalized title -> [note].
        var index: [String: [String: [ExistingAppleNote]]] = [:]
        for note in apple {
            index[note.notebook, default: [:]][normalize(note.title), default: []].append(note)
        }

        var consumed: Set<String> = []          // apple note ids already linked
        var links: [(notionId: String, appleNoteId: String)] = []
        var fresh: [String] = []

        for page in notion {
            let notebook = page.category ?? ""
            let key = normalize(page.title)
            let bucket = index[notebook]?[key]?.filter { !consumed.contains($0.noteId) } ?? []
            guard let chosen = pick(from: bucket, createdAt: page.createdAt) else {
                fresh.append(page.notionId)
                continue
            }
            consumed.insert(chosen.noteId)
            links.append((page.notionId, chosen.noteId))
        }

        // Orphans: unconsumed Apple notes, but only in notebooks that are a Notion
        // category here (so we never offer notes from unrelated notebooks).
        let categories = Set(notion.map { $0.category ?? "" })
        let orphans = apple
            .filter { categories.contains($0.notebook) && !consumed.contains($0.noteId) }
            .map { $0.noteId }

        return AdoptionResult(links: links, freshNotionIds: fresh, orphanAppleNoteIds: orphans)
    }

    /// Among same-notebook, same-title candidates, prefer one created on the same
    /// day as the Notion page; otherwise the first. nil when the bucket is empty.
    private static func pick(from notes: [ExistingAppleNote], createdAt: Date) -> ExistingAppleNote? {
        guard !notes.isEmpty else { return nil }
        if let sameDay = notes.first(where: { sameDay($0.createdAt, createdAt) }) { return sameDay }
        return notes.first
    }

    private static func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    // MARK: Title normalization (mirrors the validated Python matcher)

    private static let trailingTimestamp = try! NSRegularExpression(
        pattern: "\\s*\\d{4}-\\d{2}-\\d{2}[tT][\\d:.+\\-]*$")
    private static let nonAlphanumeric = try! NSRegularExpression(pattern: "[^a-z0-9]+")

    /// Lowercases, strips a trailing ISO timestamp Notion appends to some meeting
    /// titles ("PLW Hang2026-05-06T17:32..."), and collapses punctuation/space so
    /// "Ads with Rex / Supabase" and "ads with rex   supabase" compare equal.
    static func normalize(_ title: String) -> String {
        var s = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = replace(trailingTimestamp, in: s, with: "")
        s = replace(nonAlphanumeric, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }
}
