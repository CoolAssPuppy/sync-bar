//
//  XSyncStateTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Per-stream sync state: the initial-vs-incremental flag, cursor advance,
//  processed-id dedup + cap, timestamps, and reset.
//

import XCTest
@testable import SyncBar

final class XSyncStateTests: XCTestCase {

    /// A store backed by a throwaway suite so tests never collide or leak.
    private func makeStore(_ name: String = "x.syncState.tests.\(UUID().uuidString)") -> (XSyncStateStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (XSyncStateStore(store: defaults), defaults)
    }

    func test_fresh_state_is_initial() {
        let (store, _) = makeStore()
        let state = store.state(accountId: "u1", stream: .bookmarks)
        XCTAssertTrue(state.isInitialSync)
        XCTAssertNil(state.newestSyncedId)
        XCTAssertTrue(state.processedIds.isEmpty)
        XCTAssertNil(state.lastSuccessfulSyncAt)
    }

    func test_recordAttempt_stamps_time_without_completing() {
        let (store, _) = makeStore()
        store.recordAttempt(accountId: "u1", stream: .likes, at: Date(timeIntervalSince1970: 1000))
        let state = store.state(accountId: "u1", stream: .likes)
        XCTAssertEqual(state.lastAttemptedSyncAt, Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(state.isInitialSync, "an attempt alone must not flip the stream to incremental")
    }

    func test_recordSuccess_advances_cursor_and_records_processed() {
        let (store, _) = makeStore()
        store.recordSuccess(accountId: "u1", stream: .bookmarks,
                            newestId: "200", processedIds: ["200", "199", "198"],
                            at: Date(timeIntervalSince1970: 2000))
        let state = store.state(accountId: "u1", stream: .bookmarks)
        XCTAssertFalse(state.isInitialSync)
        XCTAssertEqual(state.newestSyncedId, "200")
        XCTAssertTrue(state.hasProcessed("199"))
        XCTAssertEqual(state.lastSuccessfulSyncAt, Date(timeIntervalSince1970: 2000))
    }

    func test_recordSuccess_with_no_new_items_keeps_cursor() {
        let (store, _) = makeStore()
        store.recordSuccess(accountId: "u1", stream: .posts, newestId: "10", processedIds: ["10"])
        store.recordSuccess(accountId: "u1", stream: .posts, newestId: nil, processedIds: [])
        XCTAssertEqual(store.state(accountId: "u1", stream: .posts).newestSyncedId, "10")
    }

    func test_processed_ids_dedupe_and_stay_newest_first() {
        let (store, _) = makeStore()
        store.recordSuccess(accountId: "u1", stream: .posts, newestId: "3", processedIds: ["3", "2"])
        store.recordSuccess(accountId: "u1", stream: .posts, newestId: "5", processedIds: ["5", "4", "3"])
        let processed = store.state(accountId: "u1", stream: .posts).processedIds
        XCTAssertEqual(processed.prefix(3).map { $0 }, ["5", "4", "3"])
        XCTAssertEqual(processed.count, Set(processed).count, "no duplicates")
        XCTAssertTrue(processed.contains("2"))
    }

    func test_processed_ids_are_capped() {
        let (store, _) = makeStore()
        let many = (0..<(XSyncStateStore.maxProcessedIds + 500)).map { String($0) }
        store.recordSuccess(accountId: "u1", stream: .likes, newestId: many.first, processedIds: many)
        XCTAssertEqual(store.state(accountId: "u1", stream: .likes).processedIds.count, XSyncStateStore.maxProcessedIds)
    }

    func test_reset_clears_state() {
        let (store, _) = makeStore()
        store.recordSuccess(accountId: "u1", stream: .bookmarks, newestId: "1", processedIds: ["1"])
        store.reset(accountId: "u1", stream: .bookmarks)
        XCTAssertTrue(store.state(accountId: "u1", stream: .bookmarks).isInitialSync)
    }

    func test_streams_are_independent() {
        let (store, _) = makeStore()
        store.recordSuccess(accountId: "u1", stream: .bookmarks, newestId: "100", processedIds: ["100"])
        XCTAssertTrue(store.state(accountId: "u1", stream: .likes).isInitialSync)
        XCTAssertFalse(store.state(accountId: "u1", stream: .bookmarks).isInitialSync)
    }
}
