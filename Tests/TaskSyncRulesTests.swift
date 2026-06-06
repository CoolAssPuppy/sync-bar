//
//  TaskSyncRulesTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Filter rules on the pure engine: excluded Notion statuses are kept out of
//  Reminders (row stays in Notion), removed reminders return when the status
//  leaves the excluded set, and completed reminders can be barred from creating
//  Notion rows.
//

import XCTest
@testable import SyncBar

final class TaskSyncRulesTests: XCTestCase {

    private func reminder(_ id: String, _ title: String, completed: Bool = false) -> ReminderRecord {
        ReminderRecord(id: id, task: CanonicalTask(title: title, isCompleted: completed), lastModified: nil)
    }
    private func row(_ id: String, _ title: String, status: String? = nil, category: String? = nil) -> RemoteTask {
        RemoteTask(id: id, task: CanonicalTask(title: title), lastEditedTime: .distantPast,
                   archived: false, rawStatus: status, categoryValue: category)
    }
    private func link(_ reminderId: String, _ pageId: String, _ title: String) -> TaskLink {
        TaskLink(reminderId: reminderId, notionPageId: pageId,
                 baseline: CanonicalTask(title: title), baselineSyncedAt: .distantPast)
    }
    private func excluding(_ statuses: [String]) -> TaskSyncRules {
        TaskSyncRules(excludedNotionStatuses: statuses)
    }

    func test_excluded_unpaired_row_is_not_brought_into_reminders() {
        let plan = TaskSyncEngine.plan(
            reminders: [], notionRows: [row("p1", "Done task", status: "Done")],
            links: [], rules: excluding(["Done"]))
        XCTAssertTrue(plan.createInReminders.isEmpty)
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func test_excluded_paired_row_removes_reminder_but_keeps_notion() {
        let plan = TaskSyncEngine.plan(
            reminders: [reminder("r1", "T")],
            notionRows: [row("p1", "T", status: "Done")],
            links: [link("r1", "p1", "T")],
            rules: excluding(["Done"]))
        XCTAssertEqual(plan.deletions, [PairDeletion(reminderId: "r1", notionPageId: nil)],
                       "the reminder is removed; the Notion page is NOT archived")
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.unchangedLinks.isEmpty, "the link is dropped")
    }

    func test_reminder_returns_when_status_leaves_excluded_set() {
        // Link was dropped when it became Done; now it's back to an active status
        // and unpaired → it should be recreated in Reminders.
        let plan = TaskSyncEngine.plan(
            reminders: [], notionRows: [row("p1", "T", status: "In progress")],
            links: [], rules: excluding(["Done"]))
        XCTAssertEqual(plan.createInReminders.map(\.notionPageId), ["p1"])
    }

    func test_excluded_match_on_first_sync_removes_reminder_no_duplicate() {
        // A reminder matches a Done Notion row on first sync → remove the reminder,
        // don't create a second Notion row.
        let plan = TaskSyncEngine.plan(
            reminders: [reminder("r1", "T")],
            notionRows: [row("p1", "T", status: "Done")],
            links: [], rules: excluding(["Done"]))
        XCTAssertEqual(plan.deletions, [PairDeletion(reminderId: "r1", notionPageId: nil)])
        XCTAssertTrue(plan.createInNotion.isEmpty)
        XCTAssertTrue(plan.matches.isEmpty)
    }

    func test_exclude_completed_reminders_skips_creating_notion_rows() {
        let plan = TaskSyncEngine.plan(
            reminders: [reminder("r1", "done", completed: true), reminder("r2", "todo", completed: false)],
            notionRows: [], links: [],
            rules: TaskSyncRules(excludeCompletedReminders: true))
        XCTAssertEqual(plan.createInNotion.map(\.reminderId), ["r2"], "only the incomplete reminder is imported")
    }

    func test_completed_reminder_still_pairs_with_existing_row() {
        let plan = TaskSyncEngine.plan(
            reminders: [reminder("r1", "T", completed: true)],
            notionRows: [row("p1", "T")], links: [],
            rules: TaskSyncRules(excludeCompletedReminders: true))
        XCTAssertEqual(plan.matches.map(\.reminderId), ["r1"], "a match still pairs; exclusion only blocks new creates")
        XCTAssertTrue(plan.createInNotion.isEmpty)
    }

    func test_no_rules_leaves_behavior_unchanged() {
        let plan = TaskSyncEngine.plan(
            reminders: [], notionRows: [row("p1", "T", status: "Done")], links: [])
        XCTAssertEqual(plan.createInReminders.map(\.notionPageId), ["p1"], "without rules, everything syncs")
    }

    // MARK: Category lane (scope)

    func test_only_in_lane_rows_are_imported_into_reminders() {
        let plan = TaskSyncEngine.plan(
            reminders: [],
            notionRows: [row("p1", "Mine", category: "Personal"),
                         row("p2", "Theirs", category: "Work"),
                         row("p3", "Untagged", category: nil)],
            links: [], categoryScope: "Personal")
        XCTAssertEqual(plan.createInReminders.map(\.notionPageId), ["p1"],
                       "out-of-lane and uncategorized rows stay out of Reminders")
        XCTAssertTrue(plan.deletions.isEmpty, "ignoring an unlinked row never deletes anything")
    }

    func test_lane_match_is_case_insensitive() {
        let plan = TaskSyncEngine.plan(
            reminders: [], notionRows: [row("p1", "T", category: "personal")],
            links: [], categoryScope: "Personal")
        XCTAssertEqual(plan.createInReminders.map(\.notionPageId), ["p1"])
    }

    func test_out_of_lane_row_does_not_pair_so_reminder_creates_in_lane() {
        // A Personal reminder with the same title as a Work row must NOT pair with
        // it — it creates its own in-lane Notion row instead.
        let plan = TaskSyncEngine.plan(
            reminders: [reminder("r1", "Shared title")],
            notionRows: [row("p1", "Shared title", category: "Work")],
            links: [], categoryScope: "Personal")
        XCTAssertEqual(plan.createInNotion.map(\.reminderId), ["r1"])
        XCTAssertTrue(plan.matches.isEmpty)
    }

    func test_linked_row_that_leaves_the_lane_is_left_alone_not_deleted() {
        // The row was paired while Personal; its category is now Work. The link is
        // honored and the reminder survives — scope governs unpaired rows only.
        let plan = TaskSyncEngine.plan(
            reminders: [reminder("r1", "T")],
            notionRows: [row("p1", "T", category: "Work")],
            links: [link("r1", "p1", "T")], categoryScope: "Personal")
        XCTAssertTrue(plan.deletions.isEmpty, "a linked row leaving the lane never deletes the reminder")
        XCTAssertEqual(plan.unchangedLinks.map(\.reminderId), ["r1"], "the pairing carries forward")
    }
}
