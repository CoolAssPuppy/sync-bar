//
//  AppleNotesEscapingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// AppleScript runs as plain text and is exposed to user-controlled note
/// titles, folder names, and OCR'd body content. A broken escape lets the
/// shell-equivalent of arbitrary AppleScript through. These tests drive the
/// real script builder (`AppleNotesDestinationClient.appleScriptSource`) so the
/// production escaping is what's under test.
final class AppleNotesEscapingTests: XCTestCase {

    private func script(folder: String = "Notes", title: String, body: String = "x") -> String {
        AppleNotesDestinationClient.appleScriptSource(folderName: folder, title: title, bodyHtml: body)
    }

    func test_double_quote_in_title_is_escaped() {
        let s = script(title: "Q2 \"planning\" deck")
        XCTAssertTrue(s.contains("Q2 \\\"planning\\\" deck"))
        XCTAssertFalse(s.contains("\"planning\""), "Raw double-quotes must not leak into the script body")
    }

    func test_backslash_escapes_before_quote_escape() {
        let s = script(title: "C:\\path\\file")
        XCTAssertTrue(s.contains("C:\\\\path\\\\file"), "Backslashes must double up")
    }

    func test_newlines_dont_break_the_property_record() {
        let s = script(title: "alpha\nbeta")
        XCTAssertFalse(s.contains("alpha\nbeta"), "Literal newlines would split the AppleScript record")
        XCTAssertTrue(s.contains("alpha\\nbeta"))
    }

    func test_carriage_returns_are_normalized_and_escaped() {
        let s = script(title: "alpha\r\nbeta\rgamma")
        XCTAssertFalse(s.contains("\r"), "Raw carriage returns terminate AppleScript string literals")
        XCTAssertTrue(s.contains("alpha\\nbeta\\ngamma"))
    }

    func test_combined_attack_string_is_neutralized() {
        // The kind of value an OCR pass could realistically produce from a
        // page containing an embedded shell-style payload.
        let nasty = "title\"; delete folder \"Inbox\"; --"
        let s = script(title: nasty)
        XCTAssertFalse(s.contains("delete folder \"Inbox\""),
                       "The escape must keep quoted AppleScript clauses inside the property string")
    }

    func test_folder_name_is_escaped_everywhere_it_appears() {
        // folderName is interpolated three times (exists, make, tell); all must escape.
        let s = script(folder: "Work\"x", title: "t")
        XCTAssertFalse(s.contains("folder \"Work\"x\""), "Unescaped folder name would break the tell block")
        XCTAssertTrue(s.contains("Work\\\"x"))
    }

    func test_html_body_escapes_markup_characters() {
        let payload = DestinationPayload(
            title: "Title <b>", body: "a & b < c > d", mermaidSource: nil,
            sourceDate: Date(), pdfData: nil, ocrProvider: "vision",
            ruleNotebookName: "NB", pageNumber: 1
        )
        let html = AppleNotesDestinationClient.buildHtml(payload: payload)
        XCTAssertTrue(html.contains("a &amp; b &lt; c &gt; d"))
        XCTAssertTrue(html.contains("<h1>Title &lt;b&gt;</h1>"))
    }

    // MARK: Notebook routing (Category -> notebook)

    private func payload(folderPath: [String]) -> DestinationPayload {
        DestinationPayload(
            title: "Note", body: "x", mermaidSource: nil, sourceDate: Date(),
            pdfData: nil, ocrProvider: nil, ruleNotebookName: "Note", pageNumber: 1,
            folderPath: folderPath
        )
    }

    func test_category_folder_path_picks_the_notebook() {
        let folder = AppleNotesDestinationClient.targetFolder(
            payload: payload(folderPath: ["Supabase"]),
            config: AppleNotesDestinationConfig(folderName: "Notes"))
        XCTAssertEqual(folder, "Supabase", "A Notion Category must route the note into that notebook")
    }

    func test_blank_folder_path_falls_back_to_configured_folder() {
        let folder = AppleNotesDestinationClient.targetFolder(
            payload: payload(folderPath: []),
            config: AppleNotesDestinationConfig(folderName: "Inbox"))
        XCTAssertEqual(folder, "Inbox", "No per-item folder (reMarkable) keeps the configured folder")
    }

    func test_blank_folder_path_and_blank_config_defaults_to_notes() {
        let folder = AppleNotesDestinationClient.targetFolder(
            payload: payload(folderPath: []),
            config: AppleNotesDestinationConfig(folderName: ""))
        XCTAssertEqual(folder, "Notes")
    }

    func test_whitespace_only_category_is_ignored() {
        let folder = AppleNotesDestinationClient.targetFolder(
            payload: payload(folderPath: ["   "]),
            config: AppleNotesDestinationConfig(folderName: "Inbox"))
        XCTAssertEqual(folder, "Inbox", "An all-whitespace Category shouldn't create a blank notebook")
    }

    // MARK: Creation-date preservation

    func test_creation_date_is_set_at_make_time() {
        // Apple Notes only accepts the date in the make-new-note call, so the
        // script must build theDate and pass both date properties there.
        var comps = DateComponents()
        comps.year = 2019; comps.month = 9; comps.day = 20; comps.hour = 8; comps.minute = 30; comps.second = 0
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let dated = AppleNotesDestinationClient.appleScriptSource(folderName: "Personal", title: "Codes & Cards", bodyHtml: "x", creationDate: date)
        XCTAssertTrue(dated.contains("set year of theDate to 2019"))
        XCTAssertTrue(dated.contains("set month of theDate to 9"))
        XCTAssertTrue(dated.contains("set day of theDate to 20"))
        XCTAssertTrue(dated.contains("creation date:theDate, modification date:theDate"),
                      "both date properties must be set in the make call")
    }

    func test_no_date_means_no_date_properties() {
        let s = AppleNotesDestinationClient.appleScriptSource(folderName: "Personal", title: "t", bodyHtml: "x", creationDate: nil)
        XCTAssertFalse(s.contains("creation date:"), "without a date, don't touch creation date")
        XCTAssertFalse(s.contains("set year of theDate"))
    }

    func test_html_renders_blocks_as_a_checklist() {
        let payload = DestinationPayload(
            title: "Groceries",
            body: "ignored when blocks are present",
            blocks: [
                .heading("Shopping"),
                .checkbox(text: "Milk", checked: false),
                .checkbox(text: "Eggs", checked: true),
                .bullet("a note")
            ],
            mermaidSource: nil, sourceDate: Date(), pdfData: nil, ocrProvider: nil,
            ruleNotebookName: "NB", pageNumber: 1
        )
        let html = AppleNotesDestinationClient.buildHtml(payload: payload)
        XCTAssertTrue(html.contains("<h2>Shopping</h2>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("&#9744; Milk"), "expected an empty ballot box, got: \(html)")
        XCTAssertTrue(html.contains("&#9745; <s>Eggs</s>"), "expected a ticked, struck item, got: \(html)")
        XCTAssertTrue(html.contains("<li>a note</li>"))
        XCTAssertFalse(html.contains("ignored when blocks are present"))
    }
}
