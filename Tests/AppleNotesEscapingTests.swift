//
//  AppleNotesEscapingTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

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
}
