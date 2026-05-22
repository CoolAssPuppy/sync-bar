//
//  NoteBlockTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NoteBlockTests: XCTestCase {

    // MARK: Per-block markdown

    func test_heading_renders_as_h2_so_it_sits_under_the_note_title() {
        XCTAssertEqual(NoteBlock.heading("Groceries").markdown, "## Groceries")
    }

    func test_paragraph_renders_verbatim() {
        XCTAssertEqual(NoteBlock.paragraph("Some prose").markdown, "Some prose")
    }

    func test_bullet_renders_with_dash() {
        XCTAssertEqual(NoteBlock.bullet("a point").markdown, "- a point")
    }

    func test_unchecked_checkbox_renders_empty_task() {
        XCTAssertEqual(NoteBlock.checkbox(text: "Buy milk", checked: false).markdown, "- [ ] Buy milk")
    }

    func test_checked_checkbox_renders_ticked_task() {
        XCTAssertEqual(NoteBlock.checkbox(text: "Buy milk", checked: true).markdown, "- [x] Buy milk")
    }

    func test_mermaid_renders_as_fenced_block() {
        XCTAssertEqual(NoteBlock.mermaid("flowchart TD\nA-->B").markdown, "```mermaid\nflowchart TD\nA-->B\n```")
    }

    // MARK: plainText (title / emptiness source)

    func test_plainText_strips_markers_and_excludes_diagrams() {
        XCTAssertEqual(NoteBlock.checkbox(text: "Buy milk", checked: true).plainText, "Buy milk")
        XCTAssertEqual(NoteBlock.heading("Title").plainText, "Title")
        XCTAssertNil(NoteBlock.mermaid("graph TD").plainText)
    }

    // MARK: NoteContent flattening

    private func sampleContent() -> NoteContent {
        NoteContent(blocks: [
            .heading("Shopping"),
            .paragraph("Pick these up on the way home."),
            .checkbox(text: "Milk", checked: false),
            .checkbox(text: "Eggs", checked: true),
            .mermaid("flowchart TD\nA-->B")
        ])
    }

    func test_plainText_joins_block_text_in_order_without_the_diagram() {
        XCTAssertEqual(sampleContent().plainText, "Shopping\nPick these up on the way home.\nMilk\nEggs")
    }

    func test_markdownBody_keeps_list_items_tight_and_excludes_mermaid() {
        let expected = """
        ## Shopping

        Pick these up on the way home.

        - [ ] Milk
        - [x] Eggs
        """
        XCTAssertEqual(sampleContent().markdownBody, expected)
    }

    func test_firstMermaid_collects_diagram_sources() {
        XCTAssertEqual(sampleContent().firstMermaid, "flowchart TD\nA-->B")
    }

    func test_firstMermaid_joins_multiple_diagrams() {
        let content = NoteContent(blocks: [.mermaid("graph A"), .paragraph("between"), .mermaid("graph B")])
        XCTAssertEqual(content.firstMermaid, "graph A\n\ngraph B")
    }

    func test_firstMermaid_is_nil_without_diagrams() {
        XCTAssertNil(NoteContent(blocks: [.paragraph("just text")]).firstMermaid)
    }

    func test_isEmpty_reflects_absence_of_blocks() {
        XCTAssertTrue(NoteContent(blocks: []).isEmpty)
        XCTAssertFalse(NoteContent(blocks: [.paragraph("x")]).isEmpty)
    }

    func test_consecutive_paragraphs_are_blank_line_separated() {
        let content = NoteContent(blocks: [.paragraph("one"), .paragraph("two")])
        XCTAssertEqual(content.markdownBody, "one\n\ntwo")
    }
}
