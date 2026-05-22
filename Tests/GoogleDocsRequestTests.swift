//
//  GoogleDocsRequestTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class GoogleDocsRequestTests: XCTestCase {

    private func dict(_ req: [String: Any], _ key: String) -> [String: Any]? { req[key] as? [String: Any] }
    private func insertText(_ req: [String: Any]) -> String? { dict(req, "insertText")?["text"] as? String }
    private func insertIndex(_ req: [String: Any]) -> Int? {
        (dict(req, "insertText")?["location"] as? [String: Any])?["index"] as? Int
    }
    private func bulletPreset(_ req: [String: Any]) -> String? { dict(req, "createParagraphBullets")?["bulletPreset"] as? String }
    private func range(_ req: [String: Any], _ key: String) -> (Int, Int)? {
        guard let r = dict(req, key)?["range"] as? [String: Any],
              let start = r["startIndex"] as? Int, let end = r["endIndex"] as? Int else { return nil }
        return (start, end)
    }
    private func namedStyle(_ req: [String: Any]) -> String? {
        (dict(req, "updateParagraphStyle")?["paragraphStyle"] as? [String: Any])?["namedStyleType"] as? String
    }
    private func strikethrough(_ req: [String: Any]) -> Bool? {
        (dict(req, "updateTextStyle")?["textStyle"] as? [String: Any])?["strikethrough"] as? Bool
    }

    private func payload(blocks: [NoteBlock] = [], body: String = "", mermaid: String? = nil) -> DestinationPayload {
        DestinationPayload(
            title: "T", body: body, blocks: blocks, mermaidSource: mermaid,
            sourceDate: Date(), pdfData: nil, ocrProvider: nil, ruleNotebookName: "note", pageNumber: 1
        )
    }

    func test_batch_requests_insert_text_then_native_formatting() {
        let requests = GoogleDocsDestinationClient.batchRequests(blocks: [
            .heading("Plan"),
            .checkbox(text: "Milk", checked: false),
            .checkbox(text: "Eggs", checked: true),
            .bullet("note")
        ], startIndex: 1)

        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(insertText(requests[0]), "Plan\nMilk\nEggs\nnote\n")
        XCTAssertEqual(insertIndex(requests[0]), 1)

        XCTAssertEqual(namedStyle(requests[1]), "HEADING_2")
        XCTAssertEqual(range(requests[1], "updateParagraphStyle")?.0, 1)
        XCTAssertEqual(range(requests[1], "updateParagraphStyle")?.1, 6)

        XCTAssertEqual(bulletPreset(requests[2]), "BULLET_CHECKBOX")
        XCTAssertEqual(range(requests[2], "createParagraphBullets")?.0, 6)
        XCTAssertEqual(range(requests[2], "createParagraphBullets")?.1, 11)

        XCTAssertEqual(bulletPreset(requests[3]), "BULLET_CHECKBOX")          // Eggs paragraph
        XCTAssertEqual(strikethrough(requests[4]), true)                      // Eggs is checked
        XCTAssertEqual(range(requests[4], "updateTextStyle")?.0, 11)
        XCTAssertEqual(range(requests[4], "updateTextStyle")?.1, 15)          // excludes the newline

        XCTAssertEqual(bulletPreset(requests[5]), "BULLET_DISC_CIRCLE_SQUARE")
    }

    func test_unchecked_checkbox_has_no_strikethrough() {
        let requests = GoogleDocsDestinationClient.batchRequests(blocks: [.checkbox(text: "open", checked: false)], startIndex: 1)
        XCTAssertEqual(requests.count, 2)  // insert + one bullet, no text style
        XCTAssertEqual(bulletPreset(requests[1]), "BULLET_CHECKBOX")
    }

    func test_leading_newlines_offset_all_indices() {
        let requests = GoogleDocsDestinationClient.batchRequests(
            blocks: [.checkbox(text: "x", checked: false)], startIndex: 50, leadingNewlines: 1
        )
        XCTAssertEqual(insertText(requests[0]), "\nx\n")
        XCTAssertEqual(insertIndex(requests[0]), 50)
        XCTAssertEqual(range(requests[1], "createParagraphBullets")?.0, 51)  // after the leading newline
        XCTAssertEqual(range(requests[1], "createParagraphBullets")?.1, 53)
    }

    func test_empty_blocks_fall_back_to_flattened_text() {
        let requests = GoogleDocsDestinationClient.contentRequests(
            payload: payload(body: "hello"), blocks: [], startIndex: 1
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(insertText(requests[0]), "hello")
    }
}
