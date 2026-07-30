//
//  LedgerSourceInventoryTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  "Which sources are connected" drives whether the Syncs screen shows the list
//  or the "add your first source" hero, and what the Connections badge counts.
//  reMarkable was once the only answer; these pin the behavior for a user who
//  has never owned one.
//

import XCTest
@testable import SyncBar

@MainActor
final class LedgerSourceInventoryTests: XCTestCase {

    private func xAccount(_ id: String) -> XAccount {
        XAccount(id: id, username: "someone", displayName: "Someone",
                 connectedAt: Date(), selectedStreams: [.bookmarks])
    }

    private func notionWorkspace(_ id: String) -> NotionWorkspace {
        NotionWorkspace(id: id, workspaceName: "Test Workspace", workspaceIcon: nil,
                        botId: "bot-\(id)", connectedAt: Date())
    }

    func test_a_twitter_account_alone_is_a_source() {
        let ledger = Ledger.shared
        ledger.upsertXAccount(xAccount("x-source-inventory"))
        defer { ledger.removeXAccount(id: "x-source-inventory") }

        XCTAssertTrue(ledger.hasAnySource)
        XCTAssertTrue(ledger.connectedSourceKinds.contains(.x))
    }

    /// A Notion workspace reads as well as writes, so connecting one gives the
    /// user a source (database backup) without adding a second connection.
    func test_a_notion_workspace_alone_is_a_source() {
        let ledger = Ledger.shared
        ledger.upsertNotionWorkspace(notionWorkspace("notion-source-inventory"))
        defer { ledger.removeNotionWorkspace(id: "notion-source-inventory") }

        XCTAssertTrue(ledger.hasAnySource)
        XCTAssertTrue(ledger.connectedSourceKinds.contains(.notion))
    }

    func test_no_connections_means_no_source() {
        let ledger = Ledger.shared
        XCTAssertFalse(ledger.hasAnySource)
        XCTAssertTrue(ledger.connectedSourceKinds.isEmpty)
    }

    /// The Connections badge counts cards, and Twitter gets one card per account.
    func test_source_count_counts_every_twitter_account() {
        let ledger = Ledger.shared
        ledger.upsertXAccount(xAccount("x-count-one"))
        ledger.upsertXAccount(xAccount("x-count-two"))
        defer {
            ledger.removeXAccount(id: "x-count-one")
            ledger.removeXAccount(id: "x-count-two")
        }

        XCTAssertEqual(ledger.connectedSourceCount, 2)
    }

    /// Notion is one card, filed under Destinations, so counting it as a source
    /// too would show the user a connection they don't have.
    func test_source_count_excludes_notion() {
        let ledger = Ledger.shared
        ledger.upsertNotionWorkspace(notionWorkspace("notion-not-counted"))
        defer { ledger.removeNotionWorkspace(id: "notion-not-counted") }

        XCTAssertEqual(ledger.connectedSourceCount, 0)
        XCTAssertEqual(ledger.connectedAppCount, 1)
    }
}
