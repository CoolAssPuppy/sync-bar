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
    /// Normalized priority: "High", "Medium", "Low", or nil. Apple Reminders has
    /// three levels; a Notion option that isn't one of these is left untouched.
    var priority: String?

    init(title: String, due: Date? = nil, isCompleted: Bool = false, notes: String? = nil, priority: String? = nil) {
        self.title = title
        self.due = due
        self.isCompleted = isCompleted
        self.notes = notes
        self.priority = priority
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
    func samePriority(as other: CanonicalTask) -> Bool {
        (priority ?? "").caseInsensitiveCompare(other.priority ?? "") == .orderedSame
    }

    /// Whole-record field equality (day-granular due, trimmed title, nil-coalesced
    /// notes). Distinct from synthesized `==`, which is exact.
    func fieldsEqual(to other: CanonicalTask, calendar: Calendar = .current) -> Bool {
        sameTitle(as: other) && sameDue(as: other, calendar: calendar)
            && sameCompletion(as: other) && sameNotes(as: other) && samePriority(as: other)
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
    /// The Notion column type backing completion: "checkbox", "status", or
    /// "select". Captured from the live schema in the editor so writes know which
    /// JSON shape to use without re-fetching. A checkbox ignores the done/not-done
    /// option names below.
    var statusPropertyType: String?
    /// The status/select option that means "done". Unused for a checkbox column.
    var statusDoneValue: String?
    /// The status/select option that means "not done", written when a task flips
    /// back to incomplete. When nil, an incomplete task leaves the column as-is.
    var statusNotDoneValue: String?
    var notesProperty: String?
    /// Notion property that holds priority, and its type ("select" or "status").
    var priorityProperty: String?
    var priorityPropertyType: String?
    /// Category "lane": the select/status column and the single option value that
    /// marks rows belonging to this sync. When set, the value is stamped on every
    /// write and only matching rows are imported into Reminders (see `categoryScope`).
    /// Both nil means no scoping — the sync owns the whole database, as before.
    var categoryProperty: String?
    var categoryPropertyType: String?
    var categoryValue: String?

    /// The lane value to scope on, or nil when no category column is configured.
    /// Drives the inbound filter and the outbound stamp.
    var categoryScope: String? {
        guard categoryProperty != nil, let value = categoryValue, !value.isEmpty else { return nil }
        return value
    }

    init(titleProperty: String,
         dueDateProperty: String? = nil,
         statusProperty: String? = nil,
         statusPropertyType: String? = nil,
         statusDoneValue: String? = nil,
         statusNotDoneValue: String? = nil,
         notesProperty: String? = nil,
         priorityProperty: String? = nil,
         priorityPropertyType: String? = nil,
         categoryProperty: String? = nil,
         categoryPropertyType: String? = nil,
         categoryValue: String? = nil) {
        self.titleProperty = titleProperty
        self.dueDateProperty = dueDateProperty
        self.statusProperty = statusProperty
        self.statusPropertyType = statusPropertyType
        self.statusDoneValue = statusDoneValue
        self.statusNotDoneValue = statusNotDoneValue
        self.notesProperty = notesProperty
        self.priorityProperty = priorityProperty
        self.priorityPropertyType = priorityPropertyType
        self.categoryProperty = categoryProperty
        self.categoryPropertyType = categoryPropertyType
        self.categoryValue = categoryValue
    }
}

/// Filter rules for a two-way sync — which tasks to keep out of one side.
/// Excluded Notion statuses are removed from Reminders (the row stays in Notion);
/// if a task later leaves those statuses it's recreated in Reminders. Completed
/// reminders can be kept from creating new Notion rows.
struct TaskSyncRules: Codable, Equatable, Hashable, Sendable {
    /// Notion status/select option names that should NOT live in Reminders.
    var excludedNotionStatuses: [String]
    /// When true, a completed reminder with no Notion counterpart won't create one.
    var excludeCompletedReminders: Bool

    init(excludedNotionStatuses: [String] = [], excludeCompletedReminders: Bool = false) {
        self.excludedNotionStatuses = excludedNotionStatuses
        self.excludeCompletedReminders = excludeCompletedReminders
    }

    var isActive: Bool { !excludedNotionStatuses.isEmpty || excludeCompletedReminders }
}

/// One bidirectional sync: a Reminders list paired with a Notion task database,
/// plus how their fields map. The two-way analog of a SyncFlow, but stored
/// directly (not flattened from a rule + binding).
struct TaskSync: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var enabled: Bool
    var remindersListId: String
    var remindersListName: String
    /// The remote side (Notion today; other trackers later) and its field mapping.
    var provider: TaskProviderConfig
    /// Filter rules. Optional so older persisted syncs (no rules key) still decode.
    var rules: TaskSyncRules?
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var lastRunStatus: RuleRunStatus
    var lastRunError: String?

    /// The active rules, defaulting to "no filtering" when none are stored.
    var activeRules: TaskSyncRules { rules ?? TaskSyncRules() }

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         remindersListId: String,
         remindersListName: String,
         provider: TaskProviderConfig,
         rules: TaskSyncRules? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         lastRunAt: Date? = nil,
         lastRunStatus: RuleRunStatus = .neverRun,
         lastRunError: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.remindersListId = remindersListId
        self.remindersListName = remindersListName
        self.provider = provider
        self.rules = rules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.lastRunError = lastRunError
    }

    // MARK: Codable (tolerant of the pre-genericized flat Notion shape)

    enum CodingKeys: String, CodingKey {
        case id, enabled, remindersListId, remindersListName, provider, rules
        case createdAt, updatedAt, lastRunAt, lastRunStatus, lastRunError
        // Legacy flat keys (pre-provider).
        case notionWorkspaceId, notionDatabaseId, notionDatabaseName, fieldMapping
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        remindersListId = try c.decode(String.self, forKey: .remindersListId)
        remindersListName = try c.decode(String.self, forKey: .remindersListName)
        rules = try c.decodeIfPresent(TaskSyncRules.self, forKey: .rules)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastRunStatus = try c.decode(RuleRunStatus.self, forKey: .lastRunStatus)
        lastRunError = try c.decodeIfPresent(String.self, forKey: .lastRunError)

        if let provider = try c.decodeIfPresent(TaskProviderConfig.self, forKey: .provider) {
            self.provider = provider
        } else {
            // Migrate a pre-genericized sync (flat Notion fields) into .notion(...).
            let workspaceId = try c.decode(String.self, forKey: .notionWorkspaceId)
            let databaseId = try c.decode(String.self, forKey: .notionDatabaseId)
            let databaseName = try c.decode(String.self, forKey: .notionDatabaseName)
            let mapping = try c.decode(TaskFieldMapping.self, forKey: .fieldMapping)
            self.provider = .notion(NotionTaskConfig(workspaceId: workspaceId, databaseId: databaseId,
                                                     databaseName: databaseName, fieldMapping: mapping))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(remindersListId, forKey: .remindersListId)
        try c.encode(remindersListName, forKey: .remindersListName)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(rules, forKey: .rules)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try c.encode(lastRunStatus, forKey: .lastRunStatus)
        try c.encodeIfPresent(lastRunError, forKey: .lastRunError)
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
