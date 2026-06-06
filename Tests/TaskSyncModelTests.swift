//
//  TaskSyncModelTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Covers the pure, EventKit-free seams of step 1: CanonicalTask's day-granular
//  field comparison + pairing, and the Reminders due-date <-> components mapping.
//

import XCTest
@testable import SyncBar

final class TaskSyncModelTests: XCTestCase {

    // MARK: Date helpers

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func test_due_components_round_trip_at_day_granularity() {
        let original = date(2026, 6, 5, 14, 30)
        let components = EventKitRemindersClient.dueComponents(from: original, calendar: cal)
        // Only Y/M/D are kept — time is dropped.
        XCTAssertEqual(components?.year, 2026)
        XCTAssertEqual(components?.month, 6)
        XCTAssertEqual(components?.day, 5)
        XCTAssertNil(components?.hour)

        let back = EventKitRemindersClient.date(fromDueComponents: components, calendar: cal)
        XCTAssertNotNil(back)
        XCTAssertTrue(cal.isDate(back!, inSameDayAs: original))
    }

    func test_nil_due_maps_both_ways() {
        XCTAssertNil(EventKitRemindersClient.dueComponents(from: nil, calendar: cal))
        XCTAssertNil(EventKitRemindersClient.date(fromDueComponents: nil, calendar: cal))
    }

    // MARK: Field comparison (day-granular due, trimmed title, nil-coalesced notes)

    func test_due_dates_match_same_day_different_time() {
        let morning = date(2026, 6, 5, 9, 0)
        let evening = date(2026, 6, 5, 21, 0)
        XCTAssertTrue(CanonicalTask.dueDatesMatch(morning, evening, calendar: cal))
        XCTAssertTrue(CanonicalTask.dueDatesMatch(nil, nil, calendar: cal))
        XCTAssertFalse(CanonicalTask.dueDatesMatch(morning, nil, calendar: cal))
        XCTAssertFalse(CanonicalTask.dueDatesMatch(morning, date(2026, 6, 6), calendar: cal))
    }

    func test_fields_equal_ignores_title_whitespace_and_time_of_day() {
        let a = CanonicalTask(title: "Email Bob", due: date(2026, 6, 5, 9), isCompleted: false, notes: "x")
        let b = CanonicalTask(title: "  Email Bob  ", due: date(2026, 6, 5, 18), isCompleted: false, notes: "x")
        XCTAssertTrue(a.fieldsEqual(to: b, calendar: cal))
    }

    func test_fields_equal_treats_nil_and_empty_notes_the_same() {
        let a = CanonicalTask(title: "T", notes: nil)
        let b = CanonicalTask(title: "T", notes: "")
        XCTAssertTrue(a.sameNotes(as: b))
        XCTAssertTrue(a.fieldsEqual(to: b))
    }

    func test_fields_differ_on_completion() {
        let a = CanonicalTask(title: "T", isCompleted: false)
        let b = CanonicalTask(title: "T", isCompleted: true)
        XCTAssertFalse(a.fieldsEqual(to: b))
        XCTAssertFalse(a.sameCompletion(as: b))
    }

    // MARK: Pairing (title + due, ignores completion/notes)

    func test_ek_priority_buckets_round_trip() {
        XCTAssertEqual(EventKitRemindersClient.priorityBucket(fromEK: 1), "High")
        XCTAssertEqual(EventKitRemindersClient.priorityBucket(fromEK: 5), "Medium")
        XCTAssertEqual(EventKitRemindersClient.priorityBucket(fromEK: 9), "Low")
        XCTAssertNil(EventKitRemindersClient.priorityBucket(fromEK: 0))
        XCTAssertEqual(EventKitRemindersClient.ekPriority(fromBucket: "High"), 1)
        XCTAssertEqual(EventKitRemindersClient.ekPriority(fromBucket: "Medium"), 5)
        XCTAssertEqual(EventKitRemindersClient.ekPriority(fromBucket: "Low"), 9)
        XCTAssertEqual(EventKitRemindersClient.ekPriority(fromBucket: nil), 0)
    }

    func test_priority_merges_disjoint_and_by_latest_on_conflict() {
        // Disjoint: reminder sets priority, Notion unchanged → reminder's kept.
        let disjoint = TaskSyncEngine.merge(
            reminder: CanonicalTask(title: "T", priority: "High"),
            notion: CanonicalTask(title: "T"),
            baseline: CanonicalTask(title: "T"),
            reminderLater: false)
        XCTAssertEqual(disjoint.priority, "High")

        // Conflict: both changed; later editor wins.
        let conflict = TaskSyncEngine.merge(
            reminder: CanonicalTask(title: "T", priority: "High"),
            notion: CanonicalTask(title: "T", priority: "Low"),
            baseline: CanonicalTask(title: "T", priority: "Medium"),
            reminderLater: false)
        XCTAssertEqual(conflict.priority, "Low")
    }

    func test_pairs_on_title_and_due_only() {
        let reminder = CanonicalTask(title: "Ship v1", due: date(2026, 6, 5, 8), isCompleted: true, notes: "done")
        let notionRow = CanonicalTask(title: "Ship v1", due: date(2026, 6, 5, 23), isCompleted: false, notes: nil)
        XCTAssertTrue(reminder.pairs(with: notionRow, calendar: cal),
                      "same title + same day pairs even when completion/notes differ")

        let differentDay = CanonicalTask(title: "Ship v1", due: date(2026, 6, 6))
        XCTAssertFalse(reminder.pairs(with: differentDay, calendar: cal))

        let differentTitle = CanonicalTask(title: "Ship v2", due: date(2026, 6, 5))
        XCTAssertFalse(reminder.pairs(with: differentTitle, calendar: cal))
    }
}
