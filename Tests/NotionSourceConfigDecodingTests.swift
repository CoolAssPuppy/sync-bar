//
//  NotionSourceConfigDecodingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// Regression: a NotionSourceConfig persisted before `dateProperty` (and the
/// other later fields) existed must still decode. A throw here drops the whole
/// rules array on load — i.e. "all my syncs disappeared".
final class NotionSourceConfigDecodingTests: XCTestCase {

    func testDecodesConfigMissingDateProperty() throws {
        // Exactly the shape persisted before dateProperty was added.
        let json = """
        {"workspaceId":"w1","workspaceName":"Prashant's Notion","databaseId":"db1",
         "databaseTitle":"Notes","titleProperty":"Title","categoryProperty":"Category"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(NotionSourceConfig.self, from: json)
        XCTAssertEqual(cfg.databaseTitle, "Notes")
        XCTAssertEqual(cfg.categoryProperty, "Category")
        XCTAssertEqual(cfg.dateProperty, "", "missing dateProperty defaults to created_time")
    }

    func testDecodesConfigMissingTitleAndCategory() throws {
        // Even older shape: only the original four fields.
        let json = """
        {"workspaceId":"w1","workspaceName":"WS","databaseId":"db1","databaseTitle":"Notes"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(NotionSourceConfig.self, from: json)
        XCTAssertEqual(cfg.titleProperty, "")
        XCTAssertEqual(cfg.categoryProperty, "Category")
    }

    func testFullSyncRuleArrayWithNotionSourceDecodes() throws {
        // A whole rules array containing the notion-source rule must survive.
        let json = """
        [{"id":"r1","enabled":true,"createdAt":0,"updatedAt":0,
          "source":{"notion":{"_0":{"workspaceId":"w1","workspaceName":"WS","databaseId":"db1","databaseTitle":"Notes","titleProperty":"Title","categoryProperty":"Category"}}},
          "destinations":[]}]
        """.data(using: .utf8)!
        let rules = try JSONDecoder().decode([SyncRule].self, from: json)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.sourceKind, .notion)
    }

    func testRoundTripPreservesDateProperty() throws {
        let cfg = NotionSourceConfig(workspaceId: "w", workspaceName: "n", databaseId: "d",
                                     databaseTitle: "Notes", dateProperty: "Created Date")
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(NotionSourceConfig.self, from: data)
        XCTAssertEqual(back.dateProperty, "Created Date")
    }
}
