//
//  NoteSyncPreviewTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NoteSyncPreviewTests: XCTestCase {

    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)!
    }
    private func cand(_ id: String, _ title: String, _ cat: String?) -> AdoptionCandidate {
        AdoptionCandidate(notionId: id, title: title, category: cat, createdAt: day("2025-10-23"))
    }
    private func note(_ id: String, _ nb: String, _ title: String) -> ExistingAppleNote {
        ExistingAppleNote(noteId: id, notebook: nb, title: title, createdAt: day("2025-10-23"))
    }

    func testCountsReflectMatcherResult() {
        let result = AdoptionResult(links: [(notionId: "n1", appleNoteId: "a1")],
                                    freshNotionIds: ["n2", "n3"],
                                    orphanAppleNoteIds: ["a9"])
        let c = NoteSyncPreview.counts(result: result, pageCount: 3)
        XCTAssertEqual(c, NoteSyncPreview.Counts(pages: 3, create: 2, keep: 1, orphans: 1))
    }

    func testReportListsCreateUpdateAndOrphan() {
        let candidates = [cand("n1", "Codes & Cards", "Personal"), cand("n2", "Benchmarks", "Supabase")]
        let apple = [note("a1", "Personal", "Codes & Cards"), note("a9", "Personal", "Old only-here")]
        let result = AdoptionResult(links: [(notionId: "n1", appleNoteId: "a1")],
                                    freshNotionIds: ["n2"],
                                    orphanAppleNoteIds: ["a9"])
        let md = NoteSyncPreview.renderMarkdown(
            candidates: candidates, apple: apple, result: result,
            fallbackNotebook: "Notes", databaseTitle: "Brain", now: day("2026-06-08"))

        XCTAssertTrue(md.contains("Nothing was written"), "Must reassure no writes happen")
        XCTAssertTrue(md.contains("kept as-is"), "matched notes are kept, not overwritten")
        XCTAssertTrue(md.contains("[Supabase] Benchmarks"), "create line")
        XCTAssertTrue(md.contains("[Personal] Codes & Cards"), "kept-as-is line")
        XCTAssertTrue(md.contains("Old only-here"), "orphan line")
        XCTAssertTrue(md.contains("| Supabase | 1 | 0 |"), "by-notebook create tally")
        XCTAssertTrue(md.contains("| Personal | 0 | 1 |"), "by-notebook kept tally")
    }

    func testUncategorizedRoutesToFallbackNotebookLabel() {
        let md = NoteSyncPreview.renderMarkdown(
            candidates: [cand("n1", "Loose", nil)], apple: [],
            result: AdoptionResult(links: [], freshNotionIds: ["n1"], orphanAppleNoteIds: []),
            fallbackNotebook: "Notes", databaseTitle: "Brain", now: day("2026-06-08"))
        XCTAssertTrue(md.contains("[Notes] Loose"), "uncategorized page routes to the fallback notebook")
        XCTAssertTrue(md.contains("uncategorized → Notes"), "by-notebook label shows the fallback")
    }

    func testEmptySectionsRenderPlaceholders() {
        let md = NoteSyncPreview.renderMarkdown(
            candidates: [], apple: [],
            result: AdoptionResult(links: [], freshNotionIds: [], orphanAppleNoteIds: []),
            fallbackNotebook: "Notes", databaseTitle: "Empty", now: day("2026-06-08"))
        XCTAssertTrue(md.contains("Nothing new to create."))
        XCTAssertTrue(md.contains("No existing notes matched."))
    }
}
