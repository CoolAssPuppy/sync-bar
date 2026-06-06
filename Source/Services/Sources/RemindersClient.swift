//
//  RemindersClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  EventKit wrapper for the Apple Reminders side of a two-way TaskSync. Unlike a
//  one-way SourceClient (read-only), this both reads and writes: the bidirectional
//  coordinator creates, updates, and deletes reminders to mirror Notion. The app
//  is non-sandboxed, so access is a TCC prompt (NSRemindersFullAccessUsageDescription)
//  with no entitlement. Identity is the stable `calendarItemIdentifier`.
//

import Foundation
import EventKit

/// A Reminders list (an EKCalendar of type `.reminder`) the user can target.
struct ReminderList: Identifiable, Equatable, Hashable, Sendable {
    var id: String      // EKCalendar.calendarIdentifier
    var name: String
}

/// One reminder, projected to the neutral `CanonicalTask` shape plus the fields
/// the merge needs: its stable id and last-modified time (the conflict tiebreak).
struct ReminderRecord: Equatable, Hashable, Sendable {
    var id: String      // EKReminder.calendarItemIdentifier
    var task: CanonicalTask
    var lastModified: Date?
}

enum RemindersError: LocalizedError, Sendable {
    case accessDenied
    case listNotFound
    case reminderNotFound
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:        return "Grant Reminders access in System Settings, then relaunch Sync Bar."
        case .listNotFound:        return "That Reminders list no longer exists."
        case .reminderNotFound:    return "That reminder no longer exists."
        case .saveFailed(let msg): return msg
        }
    }
}

/// The Reminders half of a TaskSync. A protocol so the coordinator's tests can
/// substitute an in-memory stub — EventKit can't be exercised without real TCC
/// access and would touch the user's actual reminders.
protocol RemindersClient: Sendable {
    /// Whether full access has already been granted (no prompt).
    func authorizationGranted() -> Bool
    /// Prompts for full access; returns whether it was granted.
    func requestAccess() async -> Bool
    func lists() async -> [ReminderList]
    func fetchReminders(listId: String) async throws -> [ReminderRecord]
    /// Every reminder across every list, each tagged with its list name. Used by
    /// all-lists task syncs (no single list chosen).
    func fetchAllReminders() async throws -> [ReminderRecord]
    /// Creates a reminder and returns its new stable id.
    func create(_ task: CanonicalTask, inList listId: String) async throws -> String
    func update(id: String, to task: CanonicalTask) async throws
    func delete(id: String) async throws
}

/// The real EventKit-backed client. Holds no mutable state — a fresh
/// `EKEventStore` is made per call (authorization is process/TCC-level, not
/// per-store), which keeps the type trivially `Sendable` under strict concurrency.
struct EventKitRemindersClient: RemindersClient {

    func authorizationGranted() -> Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccess() async -> Bool {
        let store = EKEventStore()
        do { return try await store.requestFullAccessToReminders() }
        catch { return false }
    }

    func lists() async -> [ReminderList] {
        let store = EKEventStore()
        return store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, name: $0.title) }
    }

    func fetchReminders(listId: String) async throws -> [ReminderRecord] {
        let store = EKEventStore()
        guard let calendar = store.calendar(withIdentifier: listId) else {
            throw RemindersError.listNotFound
        }
        let predicate = store.predicateForReminders(in: [calendar])
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { found in
                cont.resume(returning: found ?? [])
            }
        }
        return reminders.map(Self.record(from:))
    }

    func fetchAllReminders() async throws -> [ReminderRecord] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .reminder)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { found in
                cont.resume(returning: found ?? [])
            }
        }
        return reminders.map(Self.record(from:))
    }

    func create(_ task: CanonicalTask, inList listId: String) async throws -> String {
        let store = EKEventStore()
        guard let calendar = store.calendar(withIdentifier: listId) else {
            throw RemindersError.listNotFound
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        Self.apply(task, to: reminder)
        do { try store.save(reminder, commit: true) }
        catch { throw RemindersError.saveFailed(error.localizedDescription) }
        return reminder.calendarItemIdentifier
    }

    func update(id: String, to task: CanonicalTask) async throws {
        let store = EKEventStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound
        }
        Self.apply(task, to: reminder)
        // List membership is bidirectional: if the task's list changed (a Notion
        // category edit), move the reminder to the matching list. If no list with
        // that name exists, leave it where it is rather than guess.
        if let listName = task.list,
           reminder.calendar?.title.caseInsensitiveCompare(listName) != .orderedSame,
           let target = store.calendars(for: .reminder).first(where: { $0.title.caseInsensitiveCompare(listName) == .orderedSame }) {
            reminder.calendar = target
        }
        do { try store.save(reminder, commit: true) }
        catch { throw RemindersError.saveFailed(error.localizedDescription) }
    }

    func delete(id: String) async throws {
        let store = EKEventStore()
        // A reminder that's already gone is a no-op — the delete it represents
        // has effectively happened.
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        do { try store.remove(reminder, commit: true) }
        catch { throw RemindersError.saveFailed(error.localizedDescription) }
    }

    // MARK: EventKit <-> CanonicalTask mapping

    /// Projects an EKReminder to the neutral record. Due is read at day
    /// granularity (the model's single-due-date rule).
    static func record(from reminder: EKReminder) -> ReminderRecord {
        let task = CanonicalTask(
            title: reminder.title ?? "",
            due: date(fromDueComponents: reminder.dueDateComponents),
            isCompleted: reminder.isCompleted,
            notes: reminder.notes,
            priority: priorityBucket(fromEK: reminder.priority),
            list: reminder.calendar?.title)
        return ReminderRecord(id: reminder.calendarItemIdentifier,
                              task: task,
                              lastModified: reminder.lastModifiedDate)
    }

    /// Writes a canonical task onto a reminder. Setting `isCompleted` lets
    /// EventKit manage `completionDate` automatically.
    static func apply(_ task: CanonicalTask, to reminder: EKReminder, calendar: Calendar = .current) {
        reminder.title = task.title
        reminder.dueDateComponents = dueComponents(from: task.due, calendar: calendar)
        reminder.isCompleted = task.isCompleted
        reminder.notes = task.notes
        reminder.priority = ekPriority(fromBucket: task.priority)
    }

    /// EventKit priority is 0 (none) / 1–4 (high) / 5 (medium) / 6–9 (low).
    static func priorityBucket(fromEK value: Int) -> String? {
        switch value {
        case 1...4: return "High"
        case 5:     return "Medium"
        case 6...9: return "Low"
        default:    return nil
        }
    }

    static func ekPriority(fromBucket bucket: String?) -> Int {
        switch bucket?.lowercased() {
        case "high":   return 1
        case "medium": return 5
        case "low":    return 9
        default:       return 0
        }
    }

    // MARK: Pure date helpers (EventKit-free, unit-tested)

    /// A reminder's due components → a Date, at day granularity. nil when there
    /// is no due date or the components can't form a date.
    static func date(fromDueComponents components: DateComponents?, calendar: Calendar = .current) -> Date? {
        guard let components else { return nil }
        return calendar.date(from: components)
    }

    /// A Date → the year/month/day components EventKit stores as a due date.
    static func dueComponents(from date: Date?, calendar: Calendar = .current) -> DateComponents? {
        guard let date else { return nil }
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
}
