//
//  NotionBlockRenderingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NotionBlockRenderingTests: XCTestCase {

    private func payload(blocks: [NoteBlock], body: String = "", mermaid: String? = nil) -> DestinationPayload {
        DestinationPayload(
            title: "T",
            body: body,
            blocks: blocks,
            mermaidSource: mermaid,
            sourceDate: Date(),
            pdfData: nil,
            ocrProvider: nil,
            ruleNotebookName: "note",
            folderName: "",
            pageNumber: 1
        )
    }

    private func type(_ block: [String: Any]) -> String? { block["type"] as? String }
    private func checked(_ block: [String: Any]) -> Bool? { (block["to_do"] as? [String: Any])?["checked"] as? Bool }
    private func richTextCount(_ block: [String: Any], _ key: String) -> Int {
        ((block[key] as? [String: Any])?["rich_text"] as? [[String: Any]])?.count ?? -1
    }
    private func firstContent(_ block: [String: Any], _ key: String) -> String? {
        (((block[key] as? [String: Any])?["rich_text"] as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String
    }

    func test_blocks_render_as_native_notion_types() {
        let children = NotionDestinationClient.buildChildren(payload: payload(blocks: [
            .heading("Groceries"),
            .paragraph("Pick up on the way."),
            .bullet("a point"),
            .checkbox(text: "Milk", checked: false),
            .checkbox(text: "Eggs", checked: true),
            .mermaid("flowchart TD\nA-->B")
        ]))

        XCTAssertEqual(children.map(type), [
            "heading_2", "paragraph", "bulleted_list_item", "to_do", "to_do", "code"
        ])
        XCTAssertEqual(firstContent(children[0], "heading_2"), "Groceries")
        XCTAssertEqual(checked(children[3]), false)
        XCTAssertEqual(checked(children[4]), true)
        XCTAssertEqual(firstContent(children[3], "to_do"), "Milk")
        XCTAssertEqual((children[5]["code"] as? [String: Any])?["language"] as? String, "mermaid")
    }

    func test_empty_blocks_fall_back_to_body_paragraphs_and_mermaid() {
        let children = NotionDestinationClient.buildChildren(
            payload: payload(blocks: [], body: "para one\n\npara two", mermaid: "graph")
        )
        XCTAssertEqual(children.map(type), ["paragraph", "paragraph", "code"])
        XCTAssertEqual(firstContent(children[0], "paragraph"), "para one")
    }

    func test_long_text_is_split_into_2000_char_rich_text_objects() {
        let long = String(repeating: "a", count: 4500)
        let children = NotionDestinationClient.buildChildren(payload: payload(blocks: [.paragraph(long)]))
        XCTAssertEqual(richTextCount(children[0], "paragraph"), 3)  // 2000 + 2000 + 500
    }

    func test_chunked_batches_blocks_into_hundreds() {
        let blocks: [[String: Any]] = (0..<250).map { ["i": $0] }
        let batches = NotionDestinationClient.chunked(blocks)
        XCTAssertEqual(batches.map(\.count), [100, 100, 50])
    }

    func test_chunked_keeps_a_small_list_in_one_batch() {
        let blocks: [[String: Any]] = (0..<10).map { ["i": $0] }
        XCTAssertEqual(NotionDestinationClient.chunked(blocks).count, 1)
        XCTAssertTrue(NotionDestinationClient.chunked([]).isEmpty)
    }
}
