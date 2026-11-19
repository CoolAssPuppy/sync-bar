//
//  SyncStatusTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  What the app says about its own state: the one-line overview every surface
//  shows (popover header, Syncs header, menu bar tooltip) and each row's status.
//
//  Failure list, written before the code (2026-11-19):
//  Overview
//   O1  No syncs, not paused: says there are no syncs.
//   O2  No syncs, paused: still says paused (the setting is on; hiding it is how
//       the user lost track of it).
//   O3  Paused and idle: "Paused", flagged paused, warning tone.
//   O4  Paused while a manual run is in flight: says syncing, still flagged paused.
//   O5  Syncing beats failures.
//   O6  One failure: singular wording.
//   O7  Several failures: plural wording.
//   O8  Paused beats failures.
//   O9  Never run, no timer (manual only): "Not run yet".
//   O10 Never run, timer set: shows the next run time.
//   O11 Last run, no timer: shows the last run only.
//   O12 Last run and timer: shows both.
//   O13 Last run under a minute ago: "just now".
//   O14 Last run in the future (clock skew): "just now", never "in 5 min".
//   O15 Negative failure count: treated as zero.
//   O16 Only partial failures: says so, warning tone (added 2026-11-19 after
//       review: the header ignored a row that visibly failed in part).
//   O17 Failed and partial together: the full failure wins.
//   O18 Several partial: plural wording.
//  Row
//   R1  Paid source inactive beats a stored error.
//   R2  Syncing beats a stored error.
//   R3  Turned off beats a stored error.
//   R4  Error with a message: "Failed" plus the message as detail.
//   R5  Error without a message: "Failed", no detail.
//   R6  Partial: warning tone plus detail.
//   R7  Success with a date: relative time.
//   R8  Success without a date: "Synced".
//   R9  Never run: "Not synced yet".
//   R10 Stored .running while nothing runs (app quit mid-run): "Interrupted",
//       never a stale "Syncing…".
//   R11 Empty or blank error string: no detail.
//

import XCTest
@testable import SyncBar

private struct OverviewCase {
    let name: String
    let got: SyncOverview
    let headline: String
    let tone: SyncTone
    let isPaused: Bool
    init(_ name: String, _ got: SyncOverview, _ headline: String, _ tone: SyncTone, _ isPaused: Bool) {
        (self.name, self.got, self.headline, self.tone, self.isPaused) = (name, got, headline, tone, isPaused)
    }
}

private struct RowCase {
    let name: String
    let got: SyncRowStatus
    let label: String
    let tone: SyncTone
    let detail: String?
    init(_ name: String, _ got: SyncRowStatus, _ label: String, _ tone: SyncTone, _ detail: String?) {
        (self.name, self.got, self.label, self.tone, self.detail) = (name, got, label, tone, detail)
    }
}

final class SyncStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func overview(isPaused: Bool = false,
                          isSyncing: Bool = false,
                          syncCount: Int = 3,
                          failedCount: Int = 0,
                          partialCount: Int = 0,
                          lastRunAt: Date? = nil,
                          nextRunAt: Date? = nil) -> SyncOverview {
        SyncOverview.make(SyncOverview.Inputs(
            isPaused: isPaused, isSyncing: isSyncing, syncCount: syncCount, failedCount: failedCount,
            partialCount: partialCount, lastRunAt: lastRunAt, nextRunAt: nextRunAt), now: now)
    }

    private func row(isSyncing: Bool = false,
                     isEnabled: Bool = true,
                     isPaidInactive: Bool = false,
                     status: RuleRunStatus = .success,
                     lastRunAt: Date? = nil,
                     error: String? = nil) -> SyncRowStatus {
        SyncRowStatus.make(isSyncing: isSyncing, isEnabled: isEnabled, isPaidInactive: isPaidInactive,
                           lastStatus: status, lastRunAt: lastRunAt, lastError: error, now: now)
    }

    // MARK: Overview

    func test_overview_table() {
        let fiveMinAgo = now.addingTimeInterval(-300)
        let next = now.addingTimeInterval(600)
        let nextText = Formatters.shortTime.string(from: next)
        let fiveMinText = Formatters.relativeLabel(for: fiveMinAgo, relativeTo: now)

        let cases: [OverviewCase] = [
            OverviewCase("O1", overview(syncCount: 0), "No syncs yet", .neutral, false),
            OverviewCase("O2", overview(isPaused: true, syncCount: 0), "Paused", .warning, true),
            OverviewCase("O3", overview(isPaused: true, lastRunAt: fiveMinAgo), "Paused", .warning, true),
            OverviewCase("O4", overview(isPaused: true, isSyncing: true), "Syncing…", .active, true),
            OverviewCase("O5", overview(isSyncing: true, failedCount: 2), "Syncing…", .active, false),
            OverviewCase("O6", overview(failedCount: 1, lastRunAt: fiveMinAgo), "1 sync failed", .failure, false),
            OverviewCase("O7", overview(failedCount: 3), "3 syncs failed", .failure, false),
            OverviewCase("O8", overview(isPaused: true, failedCount: 2), "Paused", .warning, true),
            OverviewCase("O9", overview(), "Not run yet", .neutral, false),
            OverviewCase("O10", overview(nextRunAt: next), "Next run \(nextText)", .neutral, false),
            OverviewCase("O11", overview(lastRunAt: fiveMinAgo), "Last run \(fiveMinText)", .neutral, false),
            OverviewCase("O12", overview(lastRunAt: fiveMinAgo, nextRunAt: next),
             "Last run \(fiveMinText) · next \(nextText)", .neutral, false),
            OverviewCase("O13", overview(lastRunAt: now.addingTimeInterval(-20)), "Last run just now", .neutral, false),
            OverviewCase("O14", overview(lastRunAt: now.addingTimeInterval(300)), "Last run just now", .neutral, false),
            OverviewCase("O15", overview(failedCount: -4), "Not run yet", .neutral, false),
            OverviewCase("O16", overview(partialCount: 1), "1 sync partly failed", .warning, false),
            OverviewCase("O17", overview(failedCount: 1, partialCount: 2), "1 sync failed", .failure, false),
            OverviewCase("O18", overview(partialCount: 2), "2 syncs partly failed", .warning, false)
        ]
        for c in cases {
            XCTAssertEqual(c.got.headline, c.headline, c.name)
            XCTAssertEqual(c.got.tone, c.tone, c.name)
            XCTAssertEqual(c.got.isPaused, c.isPaused, c.name)
        }
    }

    // MARK: Row

    func test_row_table() {
        let fiveMinAgo = now.addingTimeInterval(-300)
        let fiveMinText = Formatters.relativeLabel(for: fiveMinAgo, relativeTo: now)
        let boom = "Reconnect the Notion workspace to back it up."

        let cases: [RowCase] = [
            RowCase("R1", row(isPaidInactive: true, status: .error, error: boom), "Subscription inactive", .warning, nil),
            RowCase("R2", row(isSyncing: true, status: .error, error: boom), "Syncing…", .active, nil),
            RowCase("R3", row(isEnabled: false, status: .error, error: boom), "Off", .muted, nil),
            RowCase("R4", row(status: .error, error: boom), "Failed", .failure, boom),
            RowCase("R5", row(status: .error), "Failed", .failure, nil),
            RowCase("R6", row(status: .partial, error: "2 notes failed"), "Partial", .warning, "2 notes failed"),
            RowCase("R7", row(status: .success, lastRunAt: fiveMinAgo), "Synced \(fiveMinText)", .success, nil),
            RowCase("R8", row(status: .success), "Synced", .success, nil),
            RowCase("R9", row(status: .neverRun), "Not synced yet", .neutral, nil),
            RowCase("R10", row(status: .running, lastRunAt: fiveMinAgo), "Interrupted", .warning, nil),
            RowCase("R11a", row(status: .error, error: ""), "Failed", .failure, nil),
            RowCase("R11b", row(status: .error, error: "  \n"), "Failed", .failure, nil)
        ]
        for c in cases {
            XCTAssertEqual(c.got.label, c.label, c.name)
            XCTAssertEqual(c.got.tone, c.tone, c.name)
            XCTAssertEqual(c.got.detail, c.detail, c.name)
        }
    }
}
