//
//  ReadBudgetTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The monthly read cap: accrual, exhaustion, and the month-rollover reset that
//  keeps a flat-rate subscriber's API cost bounded.
//

import XCTest
@testable import SyncBar

final class ReadBudgetTests: XCTestCase {

    private let suiteName = "com.strategicnerds.SyncBar.readbudget.tests"
    private var defaults: UserDefaults!
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func budget() -> ReadBudget { ReadBudget(defaults: defaults, timeZone: pacific) }

    private func date(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: 12))!
    }

    func test_fresh_budget_is_empty_and_not_exhausted() {
        let now = date(2026, 6, 15)
        XCTAssertEqual(budget().reads(now: now), 0)
        XCTAssertEqual(budget().remaining(now: now), ReadBudget.monthlyCap)
        XCTAssertFalse(budget().isExhausted(now: now))
    }

    func test_recording_reads_decrements_remaining() {
        let now = date(2026, 6, 15)
        budget().record(reads: 100, now: now)
        XCTAssertEqual(budget().reads(now: now), 100)
        XCTAssertEqual(budget().remaining(now: now), ReadBudget.monthlyCap - 100)
    }

    func test_reads_accumulate_within_a_month() {
        let now = date(2026, 6, 15)
        budget().record(reads: 100, now: now)
        budget().record(reads: 50, now: date(2026, 6, 20))
        XCTAssertEqual(budget().reads(now: now), 150)
    }

    func test_reaching_the_cap_exhausts_the_budget() {
        let now = date(2026, 6, 15)
        budget().record(reads: ReadBudget.monthlyCap, now: now)
        XCTAssertTrue(budget().isExhausted(now: now))
        XCTAssertEqual(budget().remaining(now: now), 0)
    }

    func test_budget_resets_when_the_month_rolls_over() {
        budget().record(reads: ReadBudget.monthlyCap, now: date(2026, 6, 28))
        let july = date(2026, 7, 1)
        XCTAssertEqual(budget().reads(now: july), 0, "a new month starts fresh")
        XCTAssertFalse(budget().isExhausted(now: july))
        // And recording in July doesn't carry June's tally forward.
        budget().record(reads: 10, now: july)
        XCTAssertEqual(budget().reads(now: july), 10)
    }

    func test_month_key_differs_across_months_and_years() {
        XCTAssertNotEqual(ReadBudget.monthKey(for: date(2026, 6, 1), in: pacific),
                          ReadBudget.monthKey(for: date(2026, 7, 1), in: pacific))
        XCTAssertNotEqual(ReadBudget.monthKey(for: date(2026, 1, 1), in: pacific),
                          ReadBudget.monthKey(for: date(2027, 1, 1), in: pacific))
    }
}
