//
//  NoteContentBuilderTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NoteContentBuilderTests: XCTestCase {

    // MARK: Typed paragraph -> block

    func test_typed_styles_map_to_their_blocks() {
        XCTAssertEqual(NoteContentBuilder.block(from: TypedParagraph(style: .heading, text: "H")), .heading("H"))
        XCTAssertEqual(NoteContentBuilder.block(from: TypedParagraph(style: .bullet, text: "B")), .bullet("B"))
        XCTAssertEqual(NoteContentBuilder.block(from: TypedParagraph(style: .bullet2, text: "B2")), .bullet("B2"))
        XCTAssertEqual(NoteContentBuilder.block(from: TypedParagraph(style: .plain, text: "P")), .paragraph("P"))
        XCTAssertEqual(NoteContentBuilder.block(from: TypedParagraph(style: .basic, text: "Ba")), .paragraph("Ba"))
        XCTAssertEqual(NoteContentBuilder.block(from: TypedParagraph(style: .bold, text: "Bo")), .paragraph("Bo"))
    }

    func test_typed_checkbox_styles_carry_checked_state() {
        XCTAssertEqual(
            NoteContentBuilder.block(from: TypedParagraph(style: .checkbox, text: "todo")),
            .checkbox(text: "todo", checked: false)
        )
        XCTAssertEqual(
            NoteContentBuilder.block(from: TypedParagraph(style: .checkboxChecked, text: "done")),
            .checkbox(text: "done", checked: true)
        )
    }

    // MARK: OCR text -> blocks

    func test_blank_or_empty_ocr_yields_no_blocks() {
        XCTAssertTrue(NoteContentBuilder.blocks(fromOCRText: "").isEmpty)
        XCTAssertTrue(NoteContentBuilder.blocks(fromOCRText: "   \n  ").isEmpty)
        XCTAssertTrue(NoteContentBuilder.blocks(fromOCRText: "[blank page]").isEmpty)
    }

    func test_task_lines_become_checkbox_blocks() {
        let blocks = NoteContentBuilder.blocks(fromOCRText: "- [ ] open\n- [x] done\n- [X] also done")
        XCTAssertEqual(blocks, [
            .checkbox(text: "open", checked: false),
            .checkbox(text: "done", checked: true),
            .checkbox(text: "also done", checked: true)
        ])
    }

    func test_asterisk_task_lines_are_recognized() {
        XCTAssertEqual(
            NoteContentBuilder.blocks(fromOCRText: "* [ ] star task"),
            [.checkbox(text: "star task", checked: false)]
        )
    }

    func test_prose_groups_into_paragraphs_split_on_blank_lines() {
        let blocks = NoteContentBuilder.blocks(fromOCRText: "first line\nstill first\n\nsecond para")
        XCTAssertEqual(blocks, [
            .paragraph("first line\nstill first"),
            .paragraph("second para")
        ])
    }

    func test_mixed_prose_and_tasks_keep_order() {
        let blocks = NoteContentBuilder.blocks(fromOCRText: "Shopping list\n- [ ] milk\n- [x] eggs\nremember receipts")
        XCTAssertEqual(blocks, [
            .paragraph("Shopping list"),
            .checkbox(text: "milk", checked: false),
            .checkbox(text: "eggs", checked: true),
            .paragraph("remember receipts")
        ])
    }

    func test_ordinary_dashes_are_not_treated_as_checkboxes() {
        XCTAssertEqual(
            NoteContentBuilder.blocks(fromOCRText: "- just a dash"),
            [.paragraph("- just a dash")]
        )
    }
}
