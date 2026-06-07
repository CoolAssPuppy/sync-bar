//
//  NotionPageReaderTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class NotionPageReaderTests: XCTestCase {

    // MARK: Page summary parsing

    private func queryResponse(results: [[String: Any]], hasMore: Bool = false, nextCursor: String? = nil) -> Data {
        var root: [String: Any] = ["results": results, "has_more": hasMore]
        if let nextCursor { root["next_cursor"] = nextCursor }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func row(id: String,
                     titleColumn: String = "Name",
                     title: String,
                     category: String? = "Supabase",
                     created: String = "2019-09-20T00:00:00.000Z",
                     edited: String = "2026-05-19T22:31:00.000Z") -> [String: Any] {
        var props: [String: Any] = [
            titleColumn: ["type": "title", "title": [["plain_text": title]]]
        ]
        if let category {
            props["Category"] = ["type": "select", "select": ["name": category]]
        } else {
            props["Category"] = ["type": "select", "select": NSNull()]
        }
        return ["id": id, "created_time": created, "last_edited_time": edited, "properties": props]
    }

    func testParsesTitleCategoryAndDates() throws {
        let data = queryResponse(results: [row(id: "p1", title: "Codes & Cards")])
        let (pages, next) = try NotionPageReader.parsePageSummaries(
            data: data, titleProperty: "Name", categoryProperty: "Category")

        XCTAssertNil(next)
        XCTAssertEqual(pages.count, 1)
        let page = try XCTUnwrap(pages.first)
        XCTAssertEqual(page.id, "p1")
        XCTAssertEqual(page.title, "Codes & Cards")
        XCTAssertEqual(page.category, "Supabase")
        // created_time preserves the original (pre-Notion) note date.
        XCTAssertLessThan(page.createdAt, page.lastEditedTime)
    }

    func testBlankCategoryIsNil() throws {
        let data = queryResponse(results: [row(id: "p2", title: "Loose page", category: nil)])
        let (pages, _) = try NotionPageReader.parsePageSummaries(
            data: data, titleProperty: "Name", categoryProperty: "Category")
        XCTAssertNil(try XCTUnwrap(pages.first).category)
    }

    func testFallsBackToTitleTypedColumnWhenPreferredEmpty() throws {
        // Database whose title column is "Heading", not "Name"; preferred is blank.
        let r = row(id: "p3", titleColumn: "Heading", title: "Found by type", category: nil)
        let (pages, _) = try NotionPageReader.parsePageSummaries(
            data: queryResponse(results: [r]), titleProperty: "", categoryProperty: "Category")
        XCTAssertEqual(try XCTUnwrap(pages.first).title, "Found by type")
    }

    func testCarriesNextCursorWhenHasMore() throws {
        let data = queryResponse(results: [row(id: "p4", title: "A")], hasMore: true, nextCursor: "cur-2")
        let (_, next) = try NotionPageReader.parsePageSummaries(
            data: data, titleProperty: "Name", categoryProperty: "Category")
        XCTAssertEqual(next, "cur-2")
    }

    func testMultiSelectCategoryTakesFirstOption() throws {
        let props: [String: Any] = [
            "Name": ["type": "title", "title": [["plain_text": "Multi"]]],
            "Category": ["type": "multi_select", "multi_select": [["name": "Personal"], ["name": "Backup"]]]
        ]
        let r: [String: Any] = ["id": "p5", "created_time": "2020-01-01T00:00:00.000Z",
                                "last_edited_time": "2020-01-02T00:00:00.000Z", "properties": props]
        let (pages, _) = try NotionPageReader.parsePageSummaries(
            data: queryResponse(results: [r]), titleProperty: "Name", categoryProperty: "Category")
        XCTAssertEqual(try XCTUnwrap(pages.first).category, "Personal")
    }

    // MARK: Block object extraction

    func testParsesBlockObjectsAndCursor() throws {
        let root: [String: Any] = [
            "results": [
                ["id": "b1", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "Hello"]]]],
                ["id": "b2", "type": "divider", "divider": [:]]
            ],
            "has_more": true, "next_cursor": "bc-2"
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let (blocks, next) = try NotionPageReader.parseBlockObjects(data: data)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(next, "bc-2")
    }
}
