//
//  SyncDatabase.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Local SQLite storage (via GRDB) for the two collections that grow and churn:
//  the sync event history and the two-way TaskLink baselines. Everything else
//  (accounts, settings, sync definitions) stays in UserDefaults — small, bounded
//  data that fits a preferences file. These two don't: the event log appends
//  continuously and the baselines are rewritten every reconciliation cycle, once
//  per paired task across every list. SQLite gives per-row writes and an ordered,
//  indexed event log instead of re-encoding one big blob each time.
//
//  The engine is the SQLite already built into macOS; GRDB is a thin Swift wrapper
//  over it. The database is a single file under Application Support, created on
//  first launch. Rows store a JSON blob of the Codable value plus a few real
//  columns for ordering and lookup, so the Swift models can evolve without a
//  schema migration each time.
//

import Foundation
import GRDB

/// SQLite-backed store for sync events and task-link baselines. Thread-safe via
/// GRDB's serial `DatabaseQueue`; callers (the @MainActor Ledger) use it
/// synchronously. Pass `url: nil` for an in-memory database (tests).
final class SyncDatabase {
    private let dbQueue: DatabaseQueue

    /// Opens (or creates) the database at `url`, or an in-memory one when nil.
    init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: url.path)
        } else {
            dbQueue = try DatabaseQueue()   // in-memory
        }
        try Self.migrator.migrate(dbQueue)
    }

    /// The default on-disk location: ~/Library/Application Support/SyncBar/sync.sqlite.
    static func defaultURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return support.appendingPathComponent("SyncBar/sync.sqlite")
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createSyncTables") { db in
            // Event log: a JSON blob plus an occurredAt column to order/trim by.
            try db.execute(sql: """
                CREATE TABLE sync_event (
                    id TEXT PRIMARY KEY NOT NULL,
                    occurredAt DOUBLE NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_sync_event_occurredAt ON sync_event(occurredAt)")
            // Baselines: one row per (sync, reminder, notion page) link.
            try db.execute(sql: """
                CREATE TABLE task_link (
                    syncId TEXT NOT NULL,
                    reminderId TEXT NOT NULL,
                    notionPageId TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (syncId, reminderId, notionPageId)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_task_link_syncId ON task_link(syncId)")
        }
        return migrator
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Events

    /// The most recent events, newest first, up to `limit`.
    func recentEvents(limit: Int) -> [SyncEvent] {
        (try? dbQueue.read { db -> [SyncEvent] in
            let rows = try Row.fetchAll(db, sql:
                "SELECT payload FROM sync_event ORDER BY occurredAt DESC LIMIT ?", arguments: [limit])
            return rows.compactMap { row in
                (row["payload"] as? Data).flatMap { try? decoder.decode(SyncEvent.self, from: $0) }
            }
        }) ?? []
    }

    /// Inserts one event and trims the log to `keeping` newest rows.
    func insertEvent(_ event: SyncEvent, keeping: Int) {
        guard let data = try? encoder.encode(event) else { return }
        try? dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_event (id, occurredAt, payload) VALUES (?, ?, ?)",
                           arguments: [event.id, event.occurredAt.timeIntervalSince1970, data])
            try db.execute(sql: """
                DELETE FROM sync_event WHERE id NOT IN (
                    SELECT id FROM sync_event ORDER BY occurredAt DESC LIMIT ?
                )
                """, arguments: [keeping])
        }
    }

    /// Replaces the entire event log (used for migration and bulk seeding).
    func replaceAllEvents(_ events: [SyncEvent]) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_event")
            for event in events {
                guard let data = try? encoder.encode(event) else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO sync_event (id, occurredAt, payload) VALUES (?, ?, ?)",
                               arguments: [event.id, event.occurredAt.timeIntervalSince1970, data])
            }
        }
    }

    func deleteAllEvents() {
        try? dbQueue.write { db in try db.execute(sql: "DELETE FROM sync_event") }
    }

    // MARK: Task links (baselines)

    func taskLinks(forSyncId id: String) -> [TaskLink] {
        (try? dbQueue.read { db -> [TaskLink] in
            let rows = try Row.fetchAll(db, sql:
                "SELECT payload FROM task_link WHERE syncId = ?", arguments: [id])
            return rows.compactMap { row in
                (row["payload"] as? Data).flatMap { try? decoder.decode(TaskLink.self, from: $0) }
            }
        }) ?? []
    }

    /// Every sync's links, keyed by sync id (used to hydrate the in-memory cache).
    func allTaskLinks() -> [String: [TaskLink]] {
        (try? dbQueue.read { db -> [String: [TaskLink]] in
            let rows = try Row.fetchAll(db, sql: "SELECT syncId, payload FROM task_link")
            var out: [String: [TaskLink]] = [:]
            for row in rows {
                guard let syncId = row["syncId"] as? String,
                      let data = row["payload"] as? Data,
                      let link = try? decoder.decode(TaskLink.self, from: data) else { continue }
                out[syncId, default: []].append(link)
            }
            return out
        }) ?? [:]
    }

    /// Replaces all links for one sync in a single transaction.
    func setTaskLinks(_ links: [TaskLink], forSyncId id: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM task_link WHERE syncId = ?", arguments: [id])
            for link in links {
                guard let data = try? encoder.encode(link) else { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO task_link (syncId, reminderId, notionPageId, payload)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [id, link.reminderId, link.notionPageId, data])
            }
        }
    }

    func deleteAllTaskLinks() {
        try? dbQueue.write { db in try db.execute(sql: "DELETE FROM task_link") }
    }
}
