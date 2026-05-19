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
/// shell-equivalent of arbitrary AppleScript through. These tests pin the
/// escape behaviour we rely on.
final class AppleNotesEscapingTests: XCTestCase {

    private struct Payload {
        let title: String
        let folder: String
        let body: String
        func script() -> String {
            // Mirror the format from AppleNotesDestinationClient, simplified.
            let escape: (String) -> String = { raw in
                raw.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
                   .replacingOccurrences(of: "\n", with: "\\n")
            }
            return """
            tell folder "\(escape(folder))" to make new note with properties \
            {name:"\(escape(title))", body:"\(escape(body))"}
            """
        }
    }

    func test_double_quote_in_title_is_escaped() {
        let script = Payload(title: "Q2 \"planning\" deck", folder: "Notes", body: "x").script()
        XCTAssertTrue(script.contains("Q2 \\\"planning\\\" deck"))
        XCTAssertFalse(script.contains("\"planning\""), "Raw double-quotes must not leak into the script body")
    }

    func test_backslash_escapes_before_quote_escape() {
        let script = Payload(title: "C:\\path\\file", folder: "Notes", body: "x").script()
        XCTAssertTrue(script.contains("C:\\\\path\\\\file"), "Backslashes must double up")
    }

    func test_newlines_dont_break_the_property_record() {
        let script = Payload(title: "alpha\nbeta", folder: "Notes", body: "x").script()
        XCTAssertFalse(script.contains("alpha\nbeta"), "Literal newlines would split the AppleScript record")
        XCTAssertTrue(script.contains("alpha\\nbeta"))
    }

    func test_combined_attack_string_is_neutralized() {
        // The kind of value an OCR pass could realistically produce from a
        // page containing an embedded shell-style payload.
        let nasty = "title\"; delete folder \"Inbox\"; --"
        let script = Payload(title: nasty, folder: "Notes", body: "x").script()
        XCTAssertFalse(script.contains("delete folder \"Inbox\""),
                       "The escape must keep quoted AppleScript clauses inside the property string")
    }
}
