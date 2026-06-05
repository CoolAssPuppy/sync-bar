//
//  TaskSync.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The model for two-way sync — Sync Bar's first bidirectional flow, between an
//  Apple Reminders list and a Notion task database. Unlike a one-way SyncFlow
//  (a reMarkable folder fanning out to write-only destinations), a TaskSync is a
//  first-class stored record because reconciliation runs in BOTH directions and
//  needs a durable identity map + last-synced baseline (see TaskLink).
//

import Foundation

/// The neutral shape both sides convert to and from, so the merge logic never
/// touches EventKit or Notion types directly. Due dates are treated at day
/// granularity throughout (a task's "single due date"): clients read and write
/// at day level, and field comparison compares calendar days, so a time-of-day
/// difference from round-tripping never reads as a change.
struct CanonicalTask: Codable, Equatable, Hashable, Sendable {
    var title: String
    var due: Date?
    var isCompleted: Bool
    var notes: String?

    init(title: String, due: Date? = nil, isCompleted: Bool = false, notes: String? = nil) {
        self.title = title
        self.due = due
        self.isCompleted = isCompleted
        self.notes = notes
    }

    // MARK: Field-level comparison (used by the three-way merge)

    /// Two due dates are "the same" when both are absent or fall on the same
    /// calendar day. Day granularity matches the single-due-date model and keeps
    /// idempotency stable across EventKit/Notion round-trips.
    static func dueDatesMatch(_ a: Date?, _ b: Date?, calendar: Calendar = .current) -> Bool {
        switch (a, b) {
        case (nil, nil):       return true
        case let (x?, y?):     return calendar.isDate(x, inSameDayAs: y)
        default:               return false
        }
    }

    func sameTitle(as other: CanonicalTask) -> Bool {
        Self.normalizedTitle(title) == Self.normalizedTitle(other.title)
    }
    func sameDue(as other: CanonicalTask, calendar: Calendar = .current) -> Bool {
        Self.dueDatesMatch(due, other.due, calendar: calendar)
    }
    func sameCompletion(as other: CanonicalTask) -> Bool { isCompleted == other.isCompleted }
    func sameNotes(as other: CanonicalTask) -> Bool { (notes ?? "") == (other.notes ?? "") }

    /// Whole-record field equality (day-granular due, trimmed title, nil-coalesced
    /// notes). Distinct from synthesized `==`, which is exact.
    func fieldsEqual(to other: CanonicalTask, calendar: Calendar = .current) -> Bool {
        sameTitle(as: other) && sameDue(as: other, calendar: calendar)
            && sameCompletion(as: other) && sameNotes(as: other)
    }

    /// First-sync pairing test: an unpaired Reminder and an unpaired Notion row
    /// are the same task when their titles and due dates match.
    func pairs(with other: CanonicalTask, calendar: Calendar = .current) -> Bool {
        sameTitle(as: other) && sameDue(as: other, calendar: calendar)
    }

    static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which Notion property each canonical field maps to. The Reminders side is
/// fixed (EKReminder title / dueDateComponents / isCompleted / notes); only the
/// Notion column names vary per database, chosen in the editor from the live
/// schema. The title property is required; the rest are optional.
struct TaskFieldMapping: Codable, Equatable, Hashable, Sendable {
    var titleProperty: String
    var dueDateProperty: String?
    var statusProperty: String?
    /// The status/select option (or, for a checkbox property, ignored) that means
    /// "done". When the status property is a checkbox this is left nil.
    var statusDoneValue: String?
    var notesProperty: String?

    init(titleProperty: String,
         dueDateProperty: String? = nil,
         statusProperty: String? = nil,
         statusDoneValue: String? = nil,
         notesProperty: String? = nil) {
        self.titleProperty = titleProperty
        self.dueDateProperty = dueDateProperty
        self.statusProperty = statusProperty
        self.statusDoneValue = statusDoneValue
        self.notesProperty = notesProperty
    }
}

/// One bidirectional sync: a Reminders list paired with a Notion task database,
/// plus how their fields map. The two-way analog of a SyncFlow, but stored
/// directly (not flattened from a rule + binding).
struct TaskSync: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var enabled: Bool
    var remindersListId: String
    var remindersListName: String
    var notionWorkspaceId: String
    var notionDatabaseId: String
    var notionDatabaseName: String
    var fieldMapping: TaskFieldMapping
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var lastRunStatus: RuleRunStatus
    var lastRunError: String?

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         remindersListId: String,
         remindersListName: String,
         notionWorkspaceId: String,
         notionDatabaseId: String,
         notionDatabaseName: String,
         fieldMapping: TaskFieldMapping,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         lastRunAt: Date? = nil,
         lastRunStatus: RuleRunStatus = .neverRun,
         lastRunError: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.remindersListId = remindersListId
        self.remindersListName = remindersListName
        self.notionWorkspaceId = notionWorkspaceId
        self.notionDatabaseId = notionDatabaseId
        self.notionDatabaseName = notionDatabaseName
        self.fieldMapping = fieldMapping
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.lastRunError = lastRunError
    }
}

/// The durable link between one Reminder and one Notion page, plus the last
/// agreed-upon value of the task (the baseline). The three-way merge needs both:
/// the id pair to know they're the same task forever after first-sync pairing,
/// and the baseline to tell which side changed which field since last cycle.
struct TaskLink: Codable, Equatable, Hashable, Sendable {
    var reminderId: String
    var notionPageId: String
    var baseline: CanonicalTask
    var baselineSyncedAt: Date
}
