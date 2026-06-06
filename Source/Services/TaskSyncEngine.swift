//
//  TaskSyncEngine.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The pure heart of two-way sync: given the current Reminders + Notion state and
//  the last-synced baselines, decide what to create, update, delete, and pair —
//  with no I/O, no Ledger, no clients. This is where the locked decisions live:
//  three-way merge against the baseline, latest-edit-wins only on same-field
//  conflicts, delete propagation both ways, and first-sync pairing by title+due.
//  TaskSyncCoordinator executes the plan; this file decides it.
//

import Foundation

/// An unpaired reminder that has no Notion counterpart → create a Notion row.
struct ReminderToCreate: Equatable, Sendable {
    var reminderId: String
    var task: CanonicalTask
}

/// An unpaired Notion row that has no reminder counterpart → create a reminder.
struct NotionRowToCreate: Equatable, Sendable {
    var notionPageId: String
    var task: CanonicalTask
}

/// A paired task (either newly matched this cycle or an existing link) resolved
/// to a single merged value, with which side(s) need the merged value written.
struct PairResolution: Equatable, Sendable {
    var reminderId: String
    var notionPageId: String
    var merged: CanonicalTask
    var applyToReminder: Bool
    var applyToNotion: Bool
}

/// A link whose counterpart vanished → propagate the delete to the surviving
/// side. Exactly one id is set.
struct PairDeletion: Equatable, Sendable {
    var reminderId: String?     // delete this reminder (its Notion page is gone)
    var notionPageId: String?   // archive this Notion page (its reminder is gone)
}

/// The full set of actions one reconciliation cycle should take, plus the links
/// that need no action (their baselines carry forward unchanged).
struct TaskSyncPlan: Equatable, Sendable {
    var createInNotion: [ReminderToCreate] = []
    var createInReminders: [NotionRowToCreate] = []
    var matches: [PairResolution] = []      // first-sync pairs (new links)
    var updates: [PairResolution] = []      // existing links, reconciled
    var deletions: [PairDeletion] = []
    var unchangedLinks: [TaskLink] = []
}

enum TaskSyncEngine {

    /// Decides the plan for one cycle. `reminders`/`notionRows` are the current
    /// state of both sides; `links` are the baselines from the last cycle. `rules`
    /// filter which tasks belong on each side.
    static func plan(reminders: [ReminderRecord],
                     notionRows: [RemoteTask],
                     links: [TaskLink],
                     rules: TaskSyncRules = TaskSyncRules(),
                     calendar: Calendar = .current) -> TaskSyncPlan {
        var plan = TaskSyncPlan()

        let excluded = Set(rules.excludedNotionStatuses)
        // A Notion row whose status is excluded shouldn't live in Reminders. The
        // row stays in Notion — we only ever remove the reminder, never archive.
        func isExcluded(_ n: RemoteTask) -> Bool {
            guard let status = n.rawStatus else { return false }
            return excluded.contains(status)
        }

        let remindersById = Dictionary(reminders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Archived Notion rows count as "gone" for delete propagation.
        let liveNotionById = Dictionary(
            notionRows.filter { !$0.archived }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        var linkedReminderIds = Set<String>()
        var linkedNotionIds = Set<String>()

        // 1) Reconcile existing links (merge, delete, filter, or carry forward).
        for link in links {
            linkedReminderIds.insert(link.reminderId)
            linkedNotionIds.insert(link.notionPageId)

            let reminder = remindersById[link.reminderId]
            let notion = liveNotionById[link.notionPageId]

            switch (reminder, notion) {
            case let (r?, n?):
                if isExcluded(n) {
                    // Filtered out → remove the reminder, keep the Notion row, drop
                    // the link. If it leaves the excluded status later it re-creates.
                    plan.deletions.append(PairDeletion(reminderId: r.id, notionPageId: nil))
                    break
                }
                let reminderLater = isReminderLater(r, n)
                let merged = merge(reminder: r.task, notion: n.task, baseline: link.baseline,
                                   reminderLater: reminderLater, calendar: calendar)
                let applyToReminder = !r.task.fieldsEqual(to: merged, calendar: calendar)
                let applyToNotion = !n.task.fieldsEqual(to: merged, calendar: calendar)
                if !applyToReminder && !applyToNotion && merged.fieldsEqual(to: link.baseline, calendar: calendar) {
                    plan.unchangedLinks.append(link)
                } else {
                    plan.updates.append(PairResolution(reminderId: r.id, notionPageId: n.id,
                                                       merged: merged,
                                                       applyToReminder: applyToReminder,
                                                       applyToNotion: applyToNotion))
                }
            case (.some(let r), nil):
                // Notion side gone → the task was deleted there; delete the reminder.
                plan.deletions.append(PairDeletion(reminderId: r.id, notionPageId: nil))
            case (nil, .some(let n)):
                // Reminder gone. If the row is excluded, the filter already removed
                // it — just drop the link (don't archive, don't recreate). Otherwise
                // the user deleted the reminder → archive the Notion page.
                if !isExcluded(n) {
                    plan.deletions.append(PairDeletion(reminderId: nil, notionPageId: n.id))
                }
            case (nil, nil):
                // Both gone — nothing to do; the link simply drops.
                break
            }
        }

        // 2) Pair / create the unpaired remainder.
        let unpairedReminders = reminders.filter { !linkedReminderIds.contains($0.id) }
        let unpairedNotion = notionRows.filter { !$0.archived && !linkedNotionIds.contains($0.id) }
        var claimedNotion = Set<String>()

        for r in unpairedReminders {
            // Pair against any matching row first (even excluded ones) so an
            // excluded match removes the reminder instead of duplicating it.
            if let n = unpairedNotion.first(where: { !claimedNotion.contains($0.id)
                && r.task.pairs(with: $0.task, calendar: calendar) }) {
                claimedNotion.insert(n.id)
                if isExcluded(n) {
                    plan.deletions.append(PairDeletion(reminderId: r.id, notionPageId: nil))
                } else {
                    let reminderLater = isReminderLater(r, n)
                    let merged = merge(reminder: r.task, notion: n.task, baseline: nil,
                                       reminderLater: reminderLater, calendar: calendar)
                    plan.matches.append(PairResolution(
                        reminderId: r.id, notionPageId: n.id, merged: merged,
                        applyToReminder: !r.task.fieldsEqual(to: merged, calendar: calendar),
                        applyToNotion: !n.task.fieldsEqual(to: merged, calendar: calendar)))
                }
            } else if rules.excludeCompletedReminders && r.task.isCompleted {
                // A completed reminder with no Notion counterpart isn't imported.
                continue
            } else {
                plan.createInNotion.append(ReminderToCreate(reminderId: r.id, task: r.task))
            }
        }

        for n in unpairedNotion where !claimedNotion.contains(n.id) {
            // Excluded rows are kept out of Reminders.
            if isExcluded(n) { continue }
            plan.createInReminders.append(NotionRowToCreate(notionPageId: n.id, task: n.task))
        }

        return plan
    }

    /// Whether the reminder's edit is newer than the Notion row's. Ties resolve to
    /// Notion (false) so the tiebreak is deterministic. A reminder with no
    /// modification date is treated as oldest.
    static func isReminderLater(_ reminder: ReminderRecord, _ notion: RemoteTask) -> Bool {
        (reminder.lastModified ?? .distantPast) > notion.lastEditedTime
    }

    /// Three-way field merge. With a baseline: a field changed on one side only
    /// takes that side; changed on both → latest-edit-wins. Without a baseline
    /// (first-sync pairing): any differing field → latest-edit-wins.
    static func merge(reminder: CanonicalTask,
                      notion: CanonicalTask,
                      baseline: CanonicalTask?,
                      reminderLater: Bool,
                      calendar: Calendar = .current) -> CanonicalTask {
        let title = resolve(reminder.title, notion.title, baseline?.title,
                            equal: { CanonicalTask.normalizedTitle($0) == CanonicalTask.normalizedTitle($1) },
                            reminderLater: reminderLater)
        let due = resolve(reminder.due, notion.due, baseline?.due,
                          equal: { CanonicalTask.dueDatesMatch($0, $1, calendar: calendar) },
                          reminderLater: reminderLater)
        let completed = resolve(reminder.isCompleted, notion.isCompleted, baseline?.isCompleted,
                                equal: { $0 == $1 }, reminderLater: reminderLater)
        let notes = resolve(reminder.notes, notion.notes, baseline?.notes,
                            equal: { ($0 ?? "") == ($1 ?? "") }, reminderLater: reminderLater)
        let priority = resolve(reminder.priority, notion.priority, baseline?.priority,
                               equal: { ($0 ?? "").caseInsensitiveCompare($1 ?? "") == .orderedSame },
                               reminderLater: reminderLater)
        return CanonicalTask(title: title, due: due, isCompleted: completed, notes: notes, priority: priority)
    }

    /// Resolves one field across the two sides and the optional baseline.
    private static func resolve<T>(_ reminderVal: T,
                                   _ notionVal: T,
                                   _ baseline: T?,
                                   equal: (T, T) -> Bool,
                                   reminderLater: Bool) -> T {
        if equal(reminderVal, notionVal) { return reminderVal }
        guard let baseline else { return reminderLater ? reminderVal : notionVal }
        let reminderChanged = !equal(reminderVal, baseline)
        let notionChanged = !equal(notionVal, baseline)
        if reminderChanged && !notionChanged { return reminderVal }
        if notionChanged && !reminderChanged { return notionVal }
        // Both changed to different values (or baseline drifted) → latest wins.
        return reminderLater ? reminderVal : notionVal
    }
}
