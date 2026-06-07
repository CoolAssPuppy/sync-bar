//
//  NoteAdoptionMatcherTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NoteAdoptionMatcherTests: XCTestCase {

    private func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func page(_ id: String, _ title: String, _ category: String?, _ created: String = "2025-10-23") -> AdoptionCandidate {
        AdoptionCandidate(notionId: id, title: title, category: category, createdAt: day(created))
    }

    private func note(_ id: String, _ notebook: String, _ title: String, _ created: String = "2025-10-23") -> ExistingAppleNote {
        ExistingAppleNote(noteId: id, notebook: notebook, title: title, createdAt: day(created))
    }

    // MARK: Normalization

    func testNormalizeStripsTrailingNotionTimestamp() {
        XCTAssertEqual(NoteAdoptionMatcher.normalize("Ads with Rex / Supabase 2025-10-23T17:45:00.000+01:00"),
                       "ads with rex supabase")
    }

    func testNormalizeCollapsesPunctuationAndCase() {
        XCTAssertEqual(NoteAdoptionMatcher.normalize("Egg, Ham, and Gruyère Complète"),
                       NoteAdoptionMatcher.normalize("egg ham and gruy re compl te"))
    }

    // MARK: Matching

    func testMatchesWithinNotebookByTitle() {
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Codes & Cards", "Personal")],
            apple: [note("a1", "Personal", "Codes & Cards"),
                    note("a2", "Supabase", "Codes & Cards")])  // wrong notebook, ignored
        XCTAssertEqual(result.links.count, 1)
        XCTAssertEqual(result.links.first?.notionId, "n1")
        XCTAssertEqual(result.links.first?.appleNoteId, "a1")
        XCTAssertTrue(result.freshNotionIds.isEmpty)
    }

    func testUnmatchedNotionPageIsFresh() {
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Benchmarks", "Supabase")],
            apple: [note("a1", "Supabase", "Something else")])
        XCTAssertEqual(result.freshNotionIds, ["n1"])
        XCTAssertTrue(result.links.isEmpty)
    }

    func testTitleTimestampJunkStillMatches() {
        // The Notion title carries an appended timestamp; the Apple note doesn't.
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Design Catchup 2026-05-18T10:00:00.000+01:00", "Supabase")],
            apple: [note("a1", "Supabase", "Design Catchup")])
        XCTAssertEqual(result.links.first?.appleNoteId, "a1")
    }

    func testDateTiebreakerPicksSameDayNote() {
        // Two same-titled notes in one notebook; the page should adopt the one
        // created on its day, not the first.
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Weekly 1:1", "Advisor", "2026-02-17")],
            apple: [note("a-old", "Advisor", "Weekly 1:1", "2026-01-10"),
                    note("a-match", "Advisor", "Weekly 1:1", "2026-02-17")])
        XCTAssertEqual(result.links.first?.appleNoteId, "a-match")
    }

    func testOneToOneClaiming() {
        // Two Notion pages, one Apple note: only the first claims it; the second
        // is fresh (we never link two pages to one note).
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Standup", "Nerds", "2026-02-17"),
                     page("n2", "Standup", "Nerds", "2026-03-17")],
            apple: [note("a1", "Nerds", "Standup", "2026-02-17")])
        XCTAssertEqual(result.links.count, 1)
        XCTAssertEqual(result.links.first?.appleNoteId, "a1")
        XCTAssertEqual(result.freshNotionIds, ["n2"])
    }

    func testOrphansAreUnmatchedNotesInCategoryNotebooks() {
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Known", "Personal")],
            apple: [note("a1", "Personal", "Known"),                  // linked
                    note("a2", "Personal", "Old only-in-apple note"), // orphan (category notebook)
                    note("a3", "Today", "Daily scratch")])            // ignored: not a category
        XCTAssertEqual(result.links.count, 1)
        XCTAssertEqual(result.orphanAppleNoteIds, ["a2"])
    }

    func testUncategorizedPageMatchesUncategorizedNotebookOnly() {
        // category nil maps to the "" notebook key; an Apple note in a real
        // notebook is not a match.
        let result = NoteAdoptionMatcher.match(
            notion: [page("n1", "Loose", nil)],
            apple: [note("a1", "Personal", "Loose")])
        XCTAssertEqual(result.freshNotionIds, ["n1"])
        XCTAssertTrue(result.orphanAppleNoteIds.isEmpty)
    }
}
