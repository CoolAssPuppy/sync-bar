//
//  SyncDatabaseTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Round-trip + trimming behavior of the SQLite store, against an in-memory
//  database so nothing touches disk.
//

import XCTest
@testable import SyncBar

final class SyncDatabaseTests: XCTestCase {

    private func makeDB() throws -> SyncDatabase { try SyncDatabase(url: nil) }

    private func event(_ id: String, at seconds: TimeInterval, name: String = "List") -> SyncEvent {
        SyncEvent(id: id, occurredAt: Date(timeIntervalSince1970: seconds),
                  ruleId: "r", ruleName: "r", eventType: .ruleRunCompleted,
                  rmNotebookName: name, rmPageId: nil, notionPageUrl: nil,
                  durationMs: nil, ocrProvider: nil, errorMessage: nil)
    }

    private func link(_ reminderId: String, _ pageId: String) -> TaskLink {
        TaskLink(reminderId: reminderId, notionPageId: pageId,
                 baseline: CanonicalTask(title: "T"), baselineSyncedAt: Date(timeIntervalSince1970: 1))
    }

    func test_events_round_trip_newest_first() throws {
        let db = try makeDB()
        db.insertEvent(event("a", at: 100), keeping: 500)
        db.insertEvent(event("b", at: 200), keeping: 500)
        XCTAssertEqual(db.recentEvents(limit: 500).map(\.id), ["b", "a"], "newest first")
    }

    func test_insert_trims_to_keeping_newest() throws {
        let db = try makeDB()
        db.insertEvent(event("a", at: 100), keeping: 2)
        db.insertEvent(event("b", at: 200), keeping: 2)
        db.insertEvent(event("c", at: 300), keeping: 2)
        XCTAssertEqual(db.recentEvents(limit: 500).map(\.id), ["c", "b"], "oldest beyond the cap is dropped")
    }

    func test_replace_and_delete_events() throws {
        let db = try makeDB()
        db.insertEvent(event("a", at: 100), keeping: 500)
        db.replaceAllEvents([event("x", at: 10), event("y", at: 20)])
        XCTAssertEqual(db.recentEvents(limit: 500).map(\.id), ["y", "x"])
        db.deleteAllEvents()
        XCTAssertTrue(db.recentEvents(limit: 500).isEmpty)
    }

    func test_task_links_round_trip_per_sync() throws {
        let db = try makeDB()
        db.setTaskLinks([link("r1", "p1"), link("r2", "p2")], forSyncId: "s1")
        db.setTaskLinks([link("r3", "p3")], forSyncId: "s2")

        XCTAssertEqual(Set(db.taskLinks(forSyncId: "s1").map(\.reminderId)), ["r1", "r2"])
        XCTAssertEqual(db.taskLinks(forSyncId: "s2").map(\.reminderId), ["r3"])
        XCTAssertEqual(db.allTaskLinks().keys.sorted(), ["s1", "s2"])
    }

    func test_setting_empty_links_clears_that_sync_only() throws {
        let db = try makeDB()
        db.setTaskLinks([link("r1", "p1")], forSyncId: "s1")
        db.setTaskLinks([link("r2", "p2")], forSyncId: "s2")
        db.setTaskLinks([], forSyncId: "s1")
        XCTAssertTrue(db.taskLinks(forSyncId: "s1").isEmpty)
        XCTAssertEqual(db.taskLinks(forSyncId: "s2").map(\.reminderId), ["r2"], "the other sync is untouched")
    }
}
