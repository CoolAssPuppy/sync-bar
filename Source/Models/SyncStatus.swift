//
//  SyncStatus.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The single answer to "what is Sync Bar doing?" Every place that shows state
//  (popover header, Syncs header, menu bar tooltip, each row) reads these two
//  values, so they can't disagree. Pure: callers pass the clock.
//

import Foundation

/// The color family a status renders in. Views map it to theme colors.
enum SyncTone: Equatable {
    case active, success, warning, failure, neutral, muted
}

/// The app-wide one-liner.
struct SyncOverview: Equatable {
    let headline: String
    let tone: SyncTone
    /// Kept separate from the headline: a manual run while paused says
    /// "Syncing…" but the paused indicator must stay visible.
    let isPaused: Bool

    struct Inputs {
        var isPaused: Bool
        var isSyncing: Bool
        var syncCount: Int
        var failedCount: Int
        var partialCount: Int
        var lastRunAt: Date?
        var nextRunAt: Date?
    }

    static func make(_ inputs: Inputs, now: Date) -> SyncOverview {
        let isPaused = inputs.isPaused
        if inputs.isSyncing { return SyncOverview(headline: "Syncing…", tone: .active, isPaused: isPaused) }
        if isPaused { return SyncOverview(headline: "Paused", tone: .warning, isPaused: true) }
        if inputs.syncCount <= 0 { return SyncOverview(headline: "No syncs yet", tone: .neutral, isPaused: false) }
        let lastRunAt = inputs.lastRunAt
        let nextRunAt = inputs.nextRunAt

        let failed = max(0, inputs.failedCount)
        if failed > 0 {
            let noun = failed == 1 ? "sync" : "syncs"
            return SyncOverview(headline: "\(failed) \(noun) failed", tone: .failure, isPaused: false)
        }
        let partial = max(0, inputs.partialCount)
        if partial > 0 {
            let noun = partial == 1 ? "sync" : "syncs"
            return SyncOverview(headline: "\(partial) \(noun) partly failed", tone: .warning, isPaused: false)
        }

        let next = nextRunAt.map { Formatters.shortTime.string(from: $0) }
        let headline: String
        switch (lastRunAt, next) {
        case let (last?, next?):
            headline = "Last run \(Formatters.relativeLabel(for: last, relativeTo: now)) · next \(next)"
        case let (last?, nil):
            headline = "Last run \(Formatters.relativeLabel(for: last, relativeTo: now))"
        case let (nil, next?):
            headline = "Next run \(next)"
        case (nil, nil):
            headline = "Not run yet"
        }
        return SyncOverview(headline: headline, tone: .neutral, isPaused: false)
    }
}

/// One sync row's status pill, plus the error to show under it.
struct SyncRowStatus: Equatable {
    let label: String
    let tone: SyncTone
    /// The last error, shown under a Failed or Partial row. Nil otherwise.
    let detail: String?

    static func make(isSyncing: Bool, isEnabled: Bool, isPaidInactive: Bool, lastStatus: RuleRunStatus,
                     lastRunAt: Date?, lastError: String?, now: Date) -> SyncRowStatus {
        if isPaidInactive { return SyncRowStatus(label: "Subscription inactive", tone: .warning, detail: nil) }
        if isSyncing { return SyncRowStatus(label: "Syncing…", tone: .active, detail: nil) }
        if !isEnabled { return SyncRowStatus(label: "Off", tone: .muted, detail: nil) }

        let error = lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (error?.isEmpty == false) ? error : nil
        switch lastStatus {
        case .error:
            return SyncRowStatus(label: "Failed", tone: .failure, detail: detail)
        case .partial:
            return SyncRowStatus(label: "Partial", tone: .warning, detail: detail)
        case .success:
            guard let lastRunAt else { return SyncRowStatus(label: "Synced", tone: .success, detail: nil) }
            let when = Formatters.relativeLabel(for: lastRunAt, relativeTo: now)
            return SyncRowStatus(label: "Synced \(when)", tone: .success, detail: nil)
        case .neverRun:
            return SyncRowStatus(label: "Not synced yet", tone: .neutral, detail: nil)
        case .running:
            // Stored as running but nothing is: the app quit mid-run.
            return SyncRowStatus(label: "Interrupted", tone: .warning, detail: nil)
        }
    }
}

// MARK: - Live inputs

extension SyncOverview {
    /// The overview for the running app, read from the coordinators and ledger.
    @MainActor
    static func current(coordinator: SyncCoordinator, taskCoordinator: TaskSyncCoordinator,
                        ledger: Ledger = .shared, settings: AppSettings = .shared,
                        ignoringPause: Bool = false, now: Date = Date()) -> SyncOverview {
        let flows = ledger.syncFlows
        let tasks = ledger.taskSyncs
        func count(_ status: RuleRunStatus) -> Int {
            flows.filter { $0.isEnabled && $0.status == status }.count
                + tasks.filter { $0.enabled && $0.lastRunStatus == status }.count
        }
        let lastRun = (flows.compactMap(\.lastRunAt) + tasks.compactMap(\.lastRunAt)).max()
        return make(Inputs(isPaused: settings.pauseSyncing && !ignoringPause,
                           isSyncing: coordinator.isSyncing || taskCoordinator.isSyncing,
                           syncCount: flows.count + tasks.count,
                           failedCount: count(.error), partialCount: count(.partial),
                           lastRunAt: lastRun, nextRunAt: coordinator.nextTickAt), now: now)
    }
}
