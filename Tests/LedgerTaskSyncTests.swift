//
//  LedgerTaskSyncTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Step 3: the Ledger's two-way task-sync state — task syncs upsert/update/remove
//  and their baseline links round-trip, with removal forgetting the baseline.
//

import XCTest
@testable import SyncBar

@MainActor
final class LedgerTaskSyncTests: XCTestCase {

    private func makeSync(id: String) -> TaskSync {
        TaskSync(id: id,
                 remindersListId: "list-1", remindersListName: "Tasks",
                 provider: .notion(NotionTaskConfig(workspaceId: "ws-1", databaseId: "db-1",
                                                    databaseName: "Tasks DB",
                                                    fieldMapping: TaskFieldMapping(titleProperty: "Name"))))
    }

    private func link(_ reminderId: String, _ pageId: String) -> TaskLink {
        TaskLink(reminderId: reminderId, notionPageId: pageId,
                 baseline: CanonicalTask(title: "T"), baselineSyncedAt: .distantPast)
    }

    func test_upsert_adds_then_updates_in_place() {
        let ledger = Ledger.shared
        let id = "ts-upsert-\(UUID().uuidString)"
        ledger.upsertTaskSync(makeSync(id: id))
        XCTAssertEqual(ledger.taskSyncs.filter { $0.id == id }.count, 1)

        var edited = makeSync(id: id)
        edited.provider = .notion(NotionTaskConfig(workspaceId: "ws-1", databaseId: "db-1",
                                                   databaseName: "Renamed DB",
                                                   fieldMapping: TaskFieldMapping(titleProperty: "Name")))
        ledger.upsertTaskSync(edited)
        XCTAssertEqual(ledger.taskSyncs.filter { $0.id == id }.count, 1, "same id updates in place")
        XCTAssertEqual(ledger.taskSyncs.first { $0.id == id }?.provider.displayName, "Renamed DB")

        ledger.removeTaskSync(id: id)
    }

    func test_links_set_and_get_round_trip() {
        let ledger = Ledger.shared
        let id = "ts-links-\(UUID().uuidString)"
        ledger.upsertTaskSync(makeSync(id: id))

        XCTAssertTrue(ledger.taskLinks(forSyncId: id).isEmpty)
        let links = [link("r1", "p1"), link("r2", "p2")]
        ledger.setTaskLinks(links, forSyncId: id)
        XCTAssertEqual(ledger.taskLinks(forSyncId: id), links)

        ledger.removeTaskSync(id: id)
    }

    func test_remove_forgets_baseline_links() {
        let ledger = Ledger.shared
        let id = "ts-remove-\(UUID().uuidString)"
        ledger.upsertTaskSync(makeSync(id: id))
        ledger.setTaskLinks([link("r1", "p1")], forSyncId: id)

        ledger.removeTaskSync(id: id)
        XCTAssertFalse(ledger.taskSyncs.contains { $0.id == id })
        XCTAssertTrue(ledger.taskLinks(forSyncId: id).isEmpty, "links are dropped with the sync")
    }

    func test_run_result_updates_status_and_timestamp() {
        let ledger = Ledger.shared
        let id = "ts-run-\(UUID().uuidString)"
        ledger.upsertTaskSync(makeSync(id: id))

        let runAt = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.updateTaskSyncRunResult(id: id, status: .success, runAt: runAt)
        let sync = ledger.taskSyncs.first { $0.id == id }
        XCTAssertEqual(sync?.lastRunStatus, .success)
        XCTAssertEqual(sync?.lastRunAt, runAt)

        ledger.removeTaskSync(id: id)
    }
}
