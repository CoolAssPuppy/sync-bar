//
//  ReadBudget.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A per-month ceiling on paid-source reads, so a flat-rate subscriber can't run
//  up an unbounded API bill. X bills per post read, so the maker's cost scales
//  with reads; this caps reads per calendar month at a number whose worst-case
//  cost stays under the subscription price. Per-device, persisted in UserDefaults,
//  and it resets when the month rolls over (Pacific, matching the daily
//  entitlement check).
//
//  It behaves like a tighter, cross-run version of `XSourceClient.maxPagesPerCrawl`:
//  a crawl stops once the month's budget is spent, and resumes next month.
//

import Foundation

struct ReadBudget {
    /// Monthly read ceiling per subscriber. ~$3.25 of X reads at $0.005 each,
    /// comfortably under the $6.99 price. One number to tune (derived as a recent
    /// real sync of ~26 reads times a 25x headroom factor).
    static let monthlyCap = 650

    private static let monthDefaultsKey = "settings.readBudget.month"
    private static let countDefaultsKey = "settings.readBudget.count"

    private let defaults: UserDefaults
    private let timeZone: TimeZone

    // Defaults to `.standard` because `AppSettings.defaults` is main-actor isolated
    // and this is constructed from non-isolated call sites. In production that is
    // the same store AppSettings writes to; under XCTest it is NOT (AppSettings uses
    // a throwaway suite), so tests MUST inject an isolated suite to avoid writing the
    // developer's real defaults. The call sites (XSourceClient, SyncCoordinator) take
    // an injectable budget for exactly this.
    init(defaults: UserDefaults = .standard,
         timeZone: TimeZone = .pacific) {
        self.defaults = defaults
        self.timeZone = timeZone
    }

    /// Reads recorded in the current month (0 once the month has rolled over).
    func reads(now: Date) -> Int {
        guard defaults.string(forKey: Self.monthDefaultsKey) == Self.monthKey(for: now, in: timeZone) else {
            return 0
        }
        return defaults.integer(forKey: Self.countDefaultsKey)
    }

    /// How many more reads are allowed this month.
    func remaining(now: Date) -> Int { max(0, Self.monthlyCap - reads(now: now)) }

    /// Whether this month's budget is spent.
    func isExhausted(now: Date) -> Bool { reads(now: now) >= Self.monthlyCap }

    /// Folds reads into the current month's tally, resetting first if the month
    /// has rolled over since the last record.
    func record(reads delta: Int, now: Date) {
        guard delta > 0 else { return }
        let current = reads(now: now)   // 0 if the stored month is stale
        defaults.set(Self.monthKey(for: now, in: timeZone), forKey: Self.monthDefaultsKey)
        defaults.set(current + delta, forKey: Self.countDefaultsKey)
    }

    /// The "YYYY-M" bucket a date falls in, in the given time zone.
    static func monthKey(for date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }
}
