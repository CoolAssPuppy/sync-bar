//
//  NotionDestinationParsingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// The Page-or-database dropdown is built from a Notion `/v1/search` response.
/// A page's title lives in whichever property has type `title` (the column name
/// varies), and the dropdown should show only top-level items (not every nested
/// page or database row).
final class NotionDestinationParsingTests: XCTestCase {

    private let json = Data("""
    {
      "results": [
        { "object": "page", "id": "p1", "parent": {"type": "workspace"},
          "properties": { "Name": { "type": "title", "title": [ {"plain_text": "Car Market (EVs)"} ] } } },
        { "object": "database", "id": "d1", "parent": {"type": "workspace"}, "title": [ {"plain_text": "Notes"} ] },
        { "object": "page", "id": "p2", "parent": {"type": "page_id", "page_id": "p1"},
          "properties": { "Name": { "type": "title", "title": [ {"plain_text": "Nested Sub Page"} ] } } },
        { "object": "page", "id": "row1", "parent": {"type": "database_id", "database_id": "d1"},
          "properties": { "Name": { "type": "title", "title": [ {"plain_text": "A Database Row"} ] } } },
        { "object": "database", "id": "d2", "parent": {"type": "workspace"}, "title": [ {"plain_text": "Apples"} ] },
        { "object": "page", "id": "p4", "parent": {"type": "page_id", "page_id": "not-shared-with-us"},
          "properties": { "Heading": { "type": "rich_text" } } }
      ]
    }
    """.utf8)

    func test_page_title_is_read_from_the_title_typed_property_not_the_key() throws {
        let page = try XCTUnwrap(try RealNotionClient.parseDestinations(json).first { $0.id == "p1" })
        XCTAssertEqual(page.title, "Car Market (EVs)")
        XCTAssertEqual(page.type, .page)
    }

    func test_page_without_a_title_property_falls_back_to_untitled() throws {
        let page = try XCTUnwrap(try RealNotionClient.parseDestinations(json).first { $0.id == "p4" })
        XCTAssertEqual(page.title, "Untitled")
    }

    func test_database_title_comes_from_the_top_level() throws {
        let db = try XCTUnwrap(try RealNotionClient.parseDestinations(json).first { $0.id == "d1" })
        XCTAssertEqual(db.title, "Notes")
        XCTAssertEqual(db.type, .database)
    }

    func test_nested_pages_and_database_rows_are_dropped() throws {
        let ids = try RealNotionClient.parseDestinations(json).map(\.id)
        XCTAssertFalse(ids.contains("p2"), "a page nested under a shared page should be hidden")
        XCTAssertFalse(ids.contains("row1"), "a database row should be hidden")
    }

    func test_top_level_items_sort_databases_first_then_alphabetically() throws {
        let titles = try RealNotionClient.parseDestinations(json).map(\.title)
        XCTAssertEqual(titles, ["Apples", "Notes", "Car Market (EVs)", "Untitled"])
    }
}
