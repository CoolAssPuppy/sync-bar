//
//  TaskSyncCoordinatorTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Step 4: the bidirectional merge engine + execution. Both sides are in-memory
//  stubs and the clock is injected, so every scenario — pairing, three-way merge,
//  latest-wins conflict, disjoint-field merge, delete propagation, idempotency —
//  is exercised deterministically.
//

import XCTest
@testable import SyncBar

@MainActor
final class TaskSyncCoordinatorTests: XCTestCase {

    // MARK: Stubs

    /// In-memory Reminders side. `lastModified` is whatever the test sets; ids are
    /// minted on create so we can assert pairing/identity.
    final class StubRemindersClient: RemindersClient, @unchecked Sendable {
        var records: [ReminderRecord]
        private(set) var created: [CanonicalTask] = []
        private(set) var updated: [(id: String, task: CanonicalTask)] = []
        private(set) var deleted: [String] = []
        private var counter = 0
        var failNextCreate = false

        init(_ records: [ReminderRecord] = []) { self.records = records }

        func authorizationGranted() -> Bool { true }
        func requestAccess() async -> Bool { true }
        func lists() async -> [ReminderList] { [ReminderList(id: "list", name: "Tasks")] }
        func fetchReminders(listId: String) async throws -> [ReminderRecord] { records }
        func fetchAllReminders() async throws -> [ReminderRecord] { records }

        func create(_ task: CanonicalTask, inList listId: String) async throws -> String {
            if failNextCreate { failNextCreate = false; throw RemindersError.saveFailed("boom") }
            counter += 1
            let id = "r-new-\(counter)"
            created.append(task)
            records.append(ReminderRecord(id: id, task: task, lastModified: Date()))
            return id
        }
        func update(id: String, to task: CanonicalTask) async throws {
            updated.append((id, task))
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].task = task }
        }
        func delete(id: String) async throws {
            deleted.append(id)
            records.removeAll { $0.id == id }
        }
    }

    /// In-memory remote (Notion) side. update/remove mutate the store so a
    /// follow-up cycle sees the post-write state.
    final class StubNotionTaskClient: TaskProvider, @unchecked Sendable {
        var rows: [RemoteTask]
        private(set) var created: [CanonicalTask] = []
        private(set) var updated: [(id: String, task: CanonicalTask)] = []
        private(set) var archived: [String] = []
        private var counter = 0

        init(_ rows: [RemoteTask] = []) { self.rows = rows }

        func fetchTasks() async throws -> [RemoteTask] { rows.filter { !$0.archived } }
        func createTask(_ task: CanonicalTask) async throws -> String {
            counter += 1
            let id = "p-new-\(counter)"
            created.append(task)
            rows.append(RemoteTask(id: id, task: task, lastEditedTime: Date(), archived: false))
            return id
        }
        func updateTask(id: String, to task: CanonicalTask) async throws {
            updated.append((id, task))
            if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].task = task }
        }
        func removeTask(id: String) async throws {
            archived.append(id)
            if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].archived = true }
        }
    }

    // MARK: Helpers

    private func makeSync() -> TaskSync {
        TaskSync(id: "ts-\(UUID().uuidString)",
                 remindersListId: "list", remindersListName: "Tasks",
                 provider: .notion(NotionTaskConfig(
                    workspaceId: "ws", databaseId: "db", databaseName: "Tasks DB",
                    fieldMapping: TaskFieldMapping(titleProperty: "Name", statusProperty: "Done?",
                                                   statusPropertyType: "checkbox"))))
    }

    private func makeCoordinator(_ reminders: StubRemindersClient,
                                 _ notion: StubNotionTaskClient,
                                 now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> (TaskSyncCoordinator, TaskSync) {
        let sync = makeSync()
        let ledger = Ledger.shared
        ledger.upsertTaskSync(sync)
        let coordinator = TaskSyncCoordinator(
            ledger: ledger,
            remindersClient: reminders,
            providerFor: { _ in notion },
            now: { now })
        return (coordinator, sync)
    }

    private func reminder(_ id: String, _ title: String, completed: Bool = false,
                          notes: String? = nil, due: Date? = nil, modified: Date? = nil) -> ReminderRecord {
        ReminderRecord(id: id, task: CanonicalTask(title: title, due: due, isCompleted: completed, notes: notes),
                       lastModified: modified)
    }
    private func row(_ id: String, _ title: String, completed: Bool = false,
                     notes: String? = nil, due: Date? = nil, edited: Date = .distantPast) -> RemoteTask {
        RemoteTask(id: id, task: CanonicalTask(title: title, due: due, isCompleted: completed, notes: notes),
                   lastEditedTime: edited, archived: false)
    }

    private func cleanup(_ sync: TaskSync) { Ledger.shared.removeTaskSync(id: sync.id) }

    // MARK: First run

    func test_empty_both_sides_is_a_noop() async {
        let r = StubRemindersClient(); let n = StubNotionTaskClient()
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)
        XCTAssertTrue(n.created.isEmpty); XCTAssertTrue(r.created.isEmpty)
        XCTAssertTrue(Ledger.shared.taskLinks(forSyncId: sync.id).isEmpty)
        cleanup(sync)
    }

    func test_first_run_reminders_only_creates_notion_rows_and_links() async {
        let r = StubRemindersClient([reminder("r1", "Email Bob"), reminder("r2", "Ship v1")])
        let n = StubNotionTaskClient()
        let (coordinator, sync) = makeCoordinator(r, n)

        await coordinator.run(sync)

        XCTAssertEqual(Set(n.created.map(\.title)), ["Email Bob", "Ship v1"])
        let links = Ledger.shared.taskLinks(forSyncId: sync.id)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(Set(links.map(\.reminderId)), ["r1", "r2"])
        cleanup(sync)
    }

    func test_first_run_notion_only_creates_reminders() async {
        let r = StubRemindersClient()
        let n = StubNotionTaskClient([row("p1", "Pay invoice")])
        let (coordinator, sync) = makeCoordinator(r, n)

        await coordinator.run(sync)

        XCTAssertEqual(r.created.map(\.title), ["Pay invoice"])
        XCTAssertEqual(Ledger.shared.taskLinks(forSyncId: sync.id).count, 1)
        cleanup(sync)
    }

    func test_first_run_pairs_same_title_and_due_without_duplicating() async {
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 9))!
        let dueOtherTime = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 20))!
        let r = StubRemindersClient([reminder("r1", "Launch", due: due)])
        let n = StubNotionTaskClient([row("p1", "Launch", due: dueOtherTime)])
        let (coordinator, sync) = makeCoordinator(r, n)

        await coordinator.run(sync)

        XCTAssertTrue(n.created.isEmpty, "no new Notion row")
        XCTAssertTrue(r.created.isEmpty, "no new reminder")
        let links = Ledger.shared.taskLinks(forSyncId: sync.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.reminderId, "r1")
        XCTAssertEqual(links.first?.notionPageId, "p1")
        cleanup(sync)
    }

    // MARK: Updates

    func test_edit_on_reminder_only_updates_notion_and_advances_baseline() async {
        // Establish a baseline first (paired, identical).
        let r = StubRemindersClient([reminder("r1", "Task", modified: Date(timeIntervalSince1970: 100))])
        let n = StubNotionTaskClient([row("p1", "Task", edited: Date(timeIntervalSince1970: 100))])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        // Now edit only the reminder's title and re-run.
        r.records[0].task.title = "Task edited"
        r.records[0].lastModified = Date(timeIntervalSince1970: 200)
        await coordinator.run(sync)

        XCTAssertEqual(n.updated.last?.task.title, "Task edited")
        XCTAssertEqual(Ledger.shared.taskLinks(forSyncId: sync.id).first?.baseline.title, "Task edited")
        cleanup(sync)
    }

    func test_edit_on_notion_only_updates_reminder() async {
        let r = StubRemindersClient([reminder("r1", "Task")])
        let n = StubNotionTaskClient([row("p1", "Task")])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        n.rows[0].task.title = "Task from Notion"
        n.rows[0].lastEditedTime = Date(timeIntervalSince1970: 500)
        await coordinator.run(sync)

        XCTAssertEqual(r.updated.last?.task.title, "Task from Notion")
        cleanup(sync)
    }

    func test_conflicting_edit_resolves_to_latest_editor() async {
        let r = StubRemindersClient([reminder("r1", "Title", modified: Date(timeIntervalSince1970: 100))])
        let n = StubNotionTaskClient([row("p1", "Title", edited: Date(timeIntervalSince1970: 100))])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        // Both change the SAME field to different values; Notion edits later.
        r.records[0].task.title = "Reminder wins?"
        r.records[0].lastModified = Date(timeIntervalSince1970: 200)
        n.rows[0].task.title = "Notion wins"
        n.rows[0].lastEditedTime = Date(timeIntervalSince1970: 300)
        await coordinator.run(sync)

        XCTAssertEqual(r.updated.last?.task.title, "Notion wins", "later edit (Notion) wins, loser overwritten")
        XCTAssertEqual(Ledger.shared.taskLinks(forSyncId: sync.id).first?.baseline.title, "Notion wins")
        cleanup(sync)
    }

    func test_disjoint_field_edits_merge_without_conflict() async {
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12))!
        let r = StubRemindersClient([reminder("r1", "T", notes: "base", modified: Date(timeIntervalSince1970: 100))])
        let n = StubNotionTaskClient([row("p1", "T", notes: "base", edited: Date(timeIntervalSince1970: 100))])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        // Reminder changes due; Notion changes notes. No real conflict.
        r.records[0].task.due = due
        r.records[0].lastModified = Date(timeIntervalSince1970: 150)
        n.rows[0].task.notes = "notion note"
        n.rows[0].lastEditedTime = Date(timeIntervalSince1970: 400)  // later, but must NOT clobber due
        await coordinator.run(sync)

        let baseline = Ledger.shared.taskLinks(forSyncId: sync.id).first?.baseline
        XCTAssertEqual(baseline?.notes, "notion note", "Notion's notes change is kept")
        XCTAssertTrue(CanonicalTask.dueDatesMatch(baseline?.due, due), "Reminder's due change is kept")
        cleanup(sync)
    }

    func test_completion_toggle_propagates() async {
        let r = StubRemindersClient([reminder("r1", "T")])
        let n = StubNotionTaskClient([row("p1", "T")])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        r.records[0].task.isCompleted = true
        r.records[0].lastModified = Date(timeIntervalSince1970: 900)
        await coordinator.run(sync)

        XCTAssertEqual(n.updated.last?.task.isCompleted, true)
        cleanup(sync)
    }

    // MARK: Deletes

    func test_delete_on_reminder_archives_notion_and_drops_link() async {
        let r = StubRemindersClient([reminder("r1", "T")])
        let n = StubNotionTaskClient([row("p1", "T")])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)
        XCTAssertEqual(Ledger.shared.taskLinks(forSyncId: sync.id).count, 1)

        r.records.removeAll()  // reminder deleted out-of-band
        await coordinator.run(sync)

        XCTAssertEqual(n.archived, ["p1"])
        XCTAssertTrue(Ledger.shared.taskLinks(forSyncId: sync.id).isEmpty)
        cleanup(sync)
    }

    func test_delete_on_notion_deletes_reminder() async {
        let r = StubRemindersClient([reminder("r1", "T")])
        let n = StubNotionTaskClient([row("p1", "T")])
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        n.rows.removeAll()  // Notion row deleted out-of-band
        await coordinator.run(sync)

        XCTAssertEqual(r.deleted, ["r1"])
        XCTAssertTrue(Ledger.shared.taskLinks(forSyncId: sync.id).isEmpty)
        cleanup(sync)
    }

    func test_new_item_missing_from_baseline_is_created_never_deleted() async {
        // A brand-new reminder with no link must be created in Notion, not treated
        // as a delete of a phantom Notion row.
        let r = StubRemindersClient([reminder("r1", "Brand new")])
        let n = StubNotionTaskClient()
        let (coordinator, sync) = makeCoordinator(r, n)
        await coordinator.run(sync)

        XCTAssertEqual(n.created.map(\.title), ["Brand new"])
        XCTAssertTrue(n.archived.isEmpty)
        XCTAssertTrue(r.deleted.isEmpty)
        cleanup(sync)
    }

    // MARK: Idempotency

    func test_second_cycle_with_no_changes_writes_nothing() async {
        let r = StubRemindersClient([reminder("r1", "Stable", modified: Date(timeIntervalSince1970: 10))])
        let n = StubNotionTaskClient([row("p1", "Stable", edited: Date(timeIntervalSince1970: 10))])
        let (coordinator, sync) = makeCoordinator(r, n)

        await coordinator.run(sync)  // pairs r1 <-> p1
        let createsAfterFirst = n.created.count + r.created.count
        let updatesBefore = n.updated.count + r.updated.count

        await coordinator.run(sync)  // nothing changed

        XCTAssertEqual(n.created.count + r.created.count, createsAfterFirst, "no new creates")
        XCTAssertEqual(n.updated.count + r.updated.count, updatesBefore, "no updates on a clean second pass")
        XCTAssertTrue(n.archived.isEmpty); XCTAssertTrue(r.deleted.isEmpty)
        XCTAssertEqual(Ledger.shared.taskLinks(forSyncId: sync.id).count, 1)
        cleanup(sync)
    }

    // MARK: Error handling

    func test_create_failure_records_error_and_preserves_no_phantom_link() async {
        let r = StubRemindersClient([reminder("r1", "Will fail")])
        let n = StubNotionTaskClient()
        n.rows = []  // create will go to Notion via createPage; make that fail instead
        let (coordinator, sync) = makeCoordinator(r, n)
        // Force the Notion create to throw by swapping in a failing client.
        let failing = FailingCreateNotionClient()
        let coordinator2 = TaskSyncCoordinator(ledger: Ledger.shared, remindersClient: r,
                                               providerFor: { _ in failing },
                                               now: { Date(timeIntervalSince1970: 1) })
        _ = coordinator  // silence unused
        await coordinator2.run(sync)

        XCTAssertTrue(Ledger.shared.taskLinks(forSyncId: sync.id).isEmpty, "no link for a failed create")
        XCTAssertEqual(Ledger.shared.taskSyncs.first { $0.id == sync.id }?.lastRunStatus, .error)
        cleanup(sync)
    }

    /// A Notion client whose create always throws, for the error path.
    final class FailingCreateNotionClient: TaskProvider, @unchecked Sendable {
        func fetchTasks() async throws -> [RemoteTask] { [] }
        func createTask(_ task: CanonicalTask) async throws -> String { throw NotionError.validationFailed("nope") }
        func updateTask(id: String, to task: CanonicalTask) async throws {}
        func removeTask(id: String) async throws {}
    }
}
