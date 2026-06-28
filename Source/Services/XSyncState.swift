//
//  XSyncState.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Per-stream sync state for the X source. Each content stream (bookmarks /
//  likes / posts) on each account is an independent sync, so it keeps its own:
//
//    * newest synced item ID  — the incremental cursor (`since_id` where the
//      endpoint supports it, otherwise the "stop here" marker)
//    * set of processed IDs   — durable dedup, the spec's primary "deliver each
//      item exactly once" mechanism for endpoints (bookmarks) that expose no
//      timestamp or incremental cursor
//    * last successful sync timestamp
//    * last attempted sync timestamp
//
//  This is the SOURCE-side dedup. The destination pipeline additionally dedupes
//  per binding (Ledger.syncedHash), so a stream feeding several destinations
//  still delivers to each exactly once. State lives in UserDefaults behind a
//  lock; reads/writes are cheap and bounded.
//

import Foundation

/// The durable sync state of one X stream on one account.
struct XStreamSyncState: Codable, Equatable, Sendable {
    /// The id of the newest item ever synced, used as the incremental cursor.
    /// nil before the first sync, which is what makes the first run a full crawl.
    var newestSyncedId: String?
    /// Recently processed item ids, newest first, capped at `maxProcessedIds`.
    /// Used to stop a crawl the moment it reaches already-synced content and to
    /// guard against re-delivering on retries.
    var processedIds: [String]
    var lastSuccessfulSyncAt: Date?
    var lastAttemptedSyncAt: Date?

    init(newestSyncedId: String? = nil,
         processedIds: [String] = [],
         lastSuccessfulSyncAt: Date? = nil,
         lastAttemptedSyncAt: Date? = nil) {
        self.newestSyncedId = newestSyncedId
        self.processedIds = processedIds
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastAttemptedSyncAt = lastAttemptedSyncAt
    }

    /// Whether the stream has never completed a sync — the cue for an initial
    /// full-history crawl rather than an incremental fetch.
    var isInitialSync: Bool { newestSyncedId == nil }

    /// Whether `id` has already been processed (and so must not be reprocessed).
    func hasProcessed(_ id: String) -> Bool { processedIds.contains(id) }
}

/// UserDefaults-backed store of per-(account, stream) X sync state. Thread-safe
/// via an internal lock; `Sendable` so the `XSourceClient` value type can hold
/// a reference across actors. Under XCTest it uses an isolated suite so test
/// runs never leak cursors into the real app.
final class XSyncStateStore: @unchecked Sendable {
    static let shared = XSyncStateStore()

    /// Cap on the retained processed-id ring. Large enough that a steady-state
    /// incremental fetch (one page) always overlaps the previous run, small
    /// enough to stay a trivially-sized preference value.
    static let maxProcessedIds = 5_000

    private let store: UserDefaults
    private let lock = NSLock()

    init(store: UserDefaults? = nil) {
        if let store {
            self.store = store
        } else if NSClassFromString("XCTestCase") != nil {
            self.store = UserDefaults(suiteName: "com.strategicnerds.SyncBar.tests") ?? .standard
        } else {
            self.store = .standard
        }
    }

    private func key(accountId: String, stream: XStream) -> String {
        "x.syncState.\(accountId).\(stream.rawValue)"
    }

    /// The stored state for a stream, or a fresh (initial-sync) state if none.
    func state(accountId: String, stream: XStream) -> XStreamSyncState {
        lock.lock(); defer { lock.unlock() }
        return load(accountId: accountId, stream: stream) ?? XStreamSyncState()
    }

    /// Stamps the last-attempted time before a fetch begins, so a run that fails
    /// partway is still visible as "tried at …".
    func recordAttempt(accountId: String, stream: XStream, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var current = load(accountId: accountId, stream: stream) ?? XStreamSyncState()
        current.lastAttemptedSyncAt = date
        save(current, accountId: accountId, stream: stream)
    }

    /// Records a successful fetch: advances the cursor to the newest processed id
    /// and folds the freshly-processed ids into the dedup ring (newest first,
    /// capped). `newestId` is the newest item delivered this run; when nil (no
    /// new items) the cursor is left untouched.
    func recordSuccess(accountId: String, stream: XStream,
                       newestId: String?, processedIds newlyProcessed: [String],
                       at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var current = load(accountId: accountId, stream: stream) ?? XStreamSyncState()
        if let newestId { current.newestSyncedId = newestId }
        if !newlyProcessed.isEmpty {
            var seen = Set<String>()
            let merged = (newlyProcessed + current.processedIds).filter { seen.insert($0).inserted }
            current.processedIds = Array(merged.prefix(Self.maxProcessedIds))
        }
        current.lastSuccessfulSyncAt = date
        save(current, accountId: accountId, stream: stream)
    }

    /// Forgets a stream's state (used when an account is disconnected) so a later
    /// reconnect starts a fresh full crawl rather than resuming a stale cursor.
    func reset(accountId: String, stream: XStream) {
        lock.lock(); defer { lock.unlock() }
        store.removeObject(forKey: key(accountId: accountId, stream: stream))
    }

    /// Forgets every stream's state for an account.
    func resetAll(accountId: String) {
        for stream in XStream.allCases { reset(accountId: accountId, stream: stream) }
    }

    // MARK: Persistence (callers hold the lock)

    private func load(accountId: String, stream: XStream) -> XStreamSyncState? {
        guard let data = store.data(forKey: key(accountId: accountId, stream: stream)) else { return nil }
        return try? JSONDecoder().decode(XStreamSyncState.self, from: data)
    }

    private func save(_ state: XStreamSyncState, accountId: String, stream: XStream) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        store.set(data, forKey: key(accountId: accountId, stream: stream))
    }
}
