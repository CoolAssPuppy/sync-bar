//
//  NotionBlockConverterTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NotionBlockConverterTests: XCTestCase {

    private func block(_ type: String, _ payload: [String: Any], hasChildren: Bool = false) -> [String: Any] {
        ["id": "b", "type": type, type: payload, "has_children": hasChildren]
    }

    private func text(_ s: String) -> [String: Any] { ["rich_text": [["plain_text": s]]] }

    func testHeadingsCollapseToHeading() {
        for t in ["heading_1", "heading_2", "heading_3"] {
            XCTAssertEqual(NotionBlockConverter.convert(block(t, text("Title"))), [.heading("Title")])
        }
    }

    func testParagraph() {
        XCTAssertEqual(NotionBlockConverter.convert(block("paragraph", text("Body"))), [.paragraph("Body")])
    }

    func testListItemsBecomeBullets() {
        XCTAssertEqual(NotionBlockConverter.convert(block("bulleted_list_item", text("a"))), [.bullet("a")])
        XCTAssertEqual(NotionBlockConverter.convert(block("numbered_list_item", text("b"))), [.bullet("b")])
    }

    func testToDoCarriesCheckedState() {
        var payload = text("Task"); payload["checked"] = true
        XCTAssertEqual(NotionBlockConverter.convert(block("to_do", payload)), [.checkbox(text: "Task", checked: true)])
        var unchecked = text("Open"); unchecked["checked"] = false
        XCTAssertEqual(NotionBlockConverter.convert(block("to_do", unchecked)), [.checkbox(text: "Open", checked: false)])
    }

    func testMermaidCodeBlockPromotesToMermaid() {
        var payload = text("graph TD; A-->B"); payload["language"] = "mermaid"
        XCTAssertEqual(NotionBlockConverter.convert(block("code", payload)), [.mermaid("graph TD; A-->B")])
    }

    func testNonMermaidCodeBecomesParagraph() {
        var payload = text("let x = 1"); payload["language"] = "swift"
        XCTAssertEqual(NotionBlockConverter.convert(block("code", payload)), [.paragraph("let x = 1")])
    }

    func testQuoteCalloutToggleBecomeParagraphs() {
        for t in ["quote", "callout", "toggle"] {
            XCTAssertEqual(NotionBlockConverter.convert(block(t, text("note"))), [.paragraph("note")])
        }
    }

    func testDividerAndEmptyProduceNothing() {
        XCTAssertEqual(NotionBlockConverter.convert(block("divider", [:])), [])
        XCTAssertEqual(NotionBlockConverter.convert(block("paragraph", text(""))), [])
    }

    func testChildPageIsSkipped() {
        XCTAssertEqual(NotionBlockConverter.convert(block("child_page", ["title": "Sub"])), [])
    }

    func testRecursesIntoToggleChildrenButNotChildPages() {
        XCTAssertTrue(NotionBlockConverter.recursesIntoChildren(block("toggle", text("x"), hasChildren: true)))
        XCTAssertFalse(NotionBlockConverter.recursesIntoChildren(block("toggle", text("x"), hasChildren: false)))
        XCTAssertFalse(NotionBlockConverter.recursesIntoChildren(block("child_page", [:], hasChildren: true)))
    }
}
