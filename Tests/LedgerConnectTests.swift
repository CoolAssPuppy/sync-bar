//
//  LedgerConnectTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// Destination-first connect: routing a folder to a destination finds or creates
/// the folder's rule and attaches the binding, converging with the source-first
/// flow on the same rule.
@MainActor
final class LedgerConnectTests: XCTestCase {

    private func markdown(_ path: String) -> DestinationConfiguration {
        .markdownFolder(MarkdownFolderDestinationConfig(folderPath: path, fileNameTemplate: "{notebook}", includeFrontmatter: true))
    }

    private func folder(_ id: String) -> RmFolder {
        RmFolder(id: id, name: "Personal", parentFolder: nil, lastModified: Date(), pageCount: 2)
    }

    func test_connect_creates_a_rule_and_binding_for_a_new_folder() {
        let ledger = Ledger.shared
        let folder = folder("f-connect-new")
        ledger.connect(folder: folder, configuration: markdown("/tmp/vault"))

        let rule = ledger.rule(forNotebookId: folder.id)
        XCTAssertEqual(rule?.sourceSummary, "Personal")
        XCTAssertEqual(rule?.destinations.count, 1)

        if let rule { ledger.deleteRule(id: rule.id) }
    }

    func test_connect_skips_an_exact_duplicate() {
        let ledger = Ledger.shared
        let folder = folder("f-connect-dup")
        ledger.connect(folder: folder, configuration: markdown("/tmp/vault"))
        ledger.connect(folder: folder, configuration: markdown("/tmp/vault"))

        XCTAssertEqual(ledger.rule(forNotebookId: folder.id)?.destinations.count, 1)
        if let rule = ledger.rule(forNotebookId: folder.id) { ledger.deleteRule(id: rule.id) }
    }

    func test_connect_adds_distinct_destinations_to_one_rule() {
        let ledger = Ledger.shared
        let folder = folder("f-connect-two")
        ledger.connect(folder: folder, configuration: markdown("/tmp/journal"))
        ledger.connect(folder: folder, configuration: markdown("/tmp/work"))

        XCTAssertEqual(ledger.rule(forNotebookId: folder.id)?.destinations.count, 2)
        if let rule = ledger.rule(forNotebookId: folder.id) { ledger.deleteRule(id: rule.id) }
    }
}
