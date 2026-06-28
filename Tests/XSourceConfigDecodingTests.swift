//
//  XSourceConfigDecodingTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Persistence regressions for the X source: an XAccount written before
//  `selectedStreams` existed must still load, and a whole rules array carrying an
//  X-sourced rule must survive a decode (a throw drops every sync).
//

import XCTest
@testable import SyncBar

final class XSourceConfigDecodingTests: XCTestCase {

    func test_xSourceConfig_round_trips() throws {
        let cfg = XSourceConfig(accountId: "42", username: "@jack", stream: .likes)
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(XSourceConfig.self, from: data)
        XCTAssertEqual(back, cfg)
    }

    func test_xAccount_missing_selectedStreams_defaults_to_all() throws {
        // The shape persisted before selectedStreams was added.
        let json = #"{"id":"42","username":"jack","displayName":"Jack D","connectedAt":0}"#
        let account = try JSONDecoder().decode(XAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account.selectedStreams, XStream.allCases)
        XCTAssertEqual(account.handle, "@jack")
    }

    func test_full_syncRule_array_with_x_source_decodes() throws {
        let json = #"""
        [{"id":"r1","enabled":true,"createdAt":0,"updatedAt":0,
          "source":{"x":{"_0":{"accountId":"42","username":"@jack","stream":"bookmarks"}}},
          "destinations":[]}]
        """#
        let rules = try JSONDecoder().decode([SyncRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.sourceKind, .x)
        XCTAssertEqual(rules.first?.sourceSummary, "@jack · Bookmarks")
    }
}
