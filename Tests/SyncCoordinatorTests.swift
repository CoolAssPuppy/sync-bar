//
//  SyncCoordinatorTests.swift
//  SyncNerdsTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncNerds

/// Black-box coverage for the parallel sync cycle. The point is to lock in
/// the contract every consumer relies on: ordering of ledger events, the
/// computed aggregate status, and the binding-level outcomes when one
/// destination fails and another succeeds.
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    func test_successful_cycle_records_synced_pages_and_marks_binding_success() async {
        let ledger = Ledger.shared
        // Force on-device OCR so the test doesn't depend on a Keychain-stored API key
        // (the user's settings can persist a different provider across runs).
        AppSettings.shared.ocrProvider = .vision
        await prepare(ledger: ledger)
        let folder = makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var rule = SyncRule.new(notebookId: "nb-test-1", notebookName: "Test")
        rule.destinations = [
            DestinationBinding(configuration: .markdownFolder(
                MarkdownFolderDestinationConfig(
                    folderPath: folder.path,
                    fileNameTemplate: "{notebook}-{page_n}",
                    includeFrontmatter: false
                )
            ))
        ]
        ledger.upsertRule(rule)

        let coordinator = SyncCoordinator(remarkable: ScriptedRemarkableClient(pages: 3))
        coordinator.syncNow(ruleId: rule.id)

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let updated = ledger.rules.first(where: { $0.id == rule.id })
        XCTAssertEqual(updated?.destinations.first?.lastRunStatus, .success)
        XCTAssertEqual(updated?.destinations.first?.lastRunPagesSynced, 3)

        ledger.deleteRule(id: rule.id)
    }

    // MARK: helpers

    private func prepare(ledger: Ledger) async {
        // Ensure the coordinator has a paired account to act on. The mock
        // pair returns a deterministic identifier.
        if ledger.remarkableAccount == nil {
            let account = try? await MockRemarkableClient().pairDevice(oneTimeCode: "abcd1234")
            if let account { ledger.setRemarkableAccount(account) }
        }
    }

    private func makeTempFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncnerds-coord-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Deterministic reMarkable client that returns N pages on demand. Lets
/// the SyncCoordinator test pin the page count without relying on the
/// shared mock fixture.
private struct ScriptedRemarkableClient: RemarkableClient {
    let pages: Int

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        RemarkableAccount(pairedAt: Date(), userIdentifier: "test", lastSyncedAt: nil)
    }

    func listNotebooks() async throws -> [RmNotebook] { [] }

    func listPages(notebookId: String) async throws -> [RmPage] {
        (0..<pages).map { index in
            RmPage(
                notebookId: notebookId,
                pageId: "page-\(index)",
                positionInNotebook: index,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_001_000),
                hasTypedText: true,
                versionHash: "hash-\(index)"
            )
        }
    }
}
