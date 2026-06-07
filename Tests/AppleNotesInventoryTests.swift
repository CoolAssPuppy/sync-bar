//
//  AppleNotesInventoryTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class AppleNotesInventoryTests: XCTestCase {

    func testParsesNotebookDateIdAndTitle() {
        let raw = "Personal\t2019-09-20\tx-coredata://ABC/p1\tCodes & Cards\n"
        let notes = AppleNotesInventory.parse(raw)
        XCTAssertEqual(notes.count, 1)
        let n = notes[0]
        XCTAssertEqual(n.notebook, "Personal")
        XCTAssertEqual(n.noteId, "x-coredata://ABC/p1")
        XCTAssertEqual(n.title, "Codes & Cards")
        XCTAssertEqual(Calendar.current.component(.year, from: n.createdAt), 2019)
    }

    func testTitleWithTabsIsRejoined() {
        // The script normally strips tabs, but be defensive: a stray tab in a
        // title shouldn't drop the note or truncate it.
        let raw = "Supabase\t2025-10-23\tid1\tAds\twith\tRex\n"
        let notes = AppleNotesInventory.parse(raw)
        XCTAssertEqual(notes.first?.title, "Ads\twith\tRex")
    }

    func testSkipsMalformedLines() {
        let raw = """
        Personal\t2020-01-01\tid1\tGood
        too few fields
        Personal\tnot-a-date\tid2\tBad date
        \tid-empty
        Nerds\t2021-02-03\tid3\tAlso good
        """
        let notes = AppleNotesInventory.parse(raw)
        XCTAssertEqual(notes.map(\.noteId), ["id1", "id3"])
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertTrue(AppleNotesInventory.parse("").isEmpty)
    }
}
