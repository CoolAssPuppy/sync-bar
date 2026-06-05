//
//  TaskSyncCoordinator.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Drives one bidirectional Reminders <-> Notion reconciliation: fetch both
//  sides, ask TaskSyncEngine for the plan, execute it through the clients, then
//  persist the advanced baselines and run status to the Ledger. The merge logic
//  lives in the (pure) engine; this file is the I/O shell around it. Clients and
//  clock are injectable so the engine + execution can be tested deterministically.
//

import Foundation

@MainActor
final class TaskSyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var activeSyncId: String?

    private let ledger: Ledger
    private let remindersClient: RemindersClient
    /// Resolves the Notion task client for a workspace. Returns nil when no token
    /// is stored (the sync can't run). Injectable for tests.
    private let notionClientFor: @MainActor (String) -> NotionTaskClient?
    private let now: @Sendable () -> Date

    init(ledger: Ledger? = nil,
         remindersClient: RemindersClient = EventKitRemindersClient(),
         notionClientFor: (@MainActor (String) -> NotionTaskClient?)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.ledger = ledger ?? Ledger.shared
        self.remindersClient = remindersClient
        self.notionClientFor = notionClientFor ?? { workspaceId in
            guard let token = KeychainStore.shared.value(for: .notionWorkspaceToken(workspaceId: workspaceId)),
                  !token.isEmpty else { return nil }
            return RealNotionTaskClient(token: token)
        }
        self.now = now
    }

    /// Reconciles every enabled task sync. Fire-and-forget entry point used by
    /// "Sync all" and the scheduled tick.
    func syncAll() {
        guard !isSyncing else { return }
        Task { await runAll() }
    }

    func runAll() async {
        guard !ledger.isDemoMode else { return }
        let syncs = ledger.taskSyncs.filter(\.enabled)
        guard !syncs.isEmpty else { return }
        isSyncing = true
        for sync in syncs {
            activeSyncId = sync.id
            await run(sync)
        }
        activeSyncId = nil
        isSyncing = false
    }

    /// Reconciles a single task sync end-to-end.
    func run(_ sync: TaskSync) async {
        guard let notion = notionClientFor(sync.notionWorkspaceId) else {
            ledger.updateTaskSyncRunResult(id: sync.id, status: .error, runAt: now(),
                                           error: "Reconnect Notion to sync tasks.")
            return
        }

        // 1) Fetch both sides + the baselines.
        let reminders: [ReminderRecord]
        let notionRows: [NotionRow]
        do {
            async let r = remindersClient.fetchReminders(listId: sync.remindersListId)
            async let n = notion.queryDatabase(databaseId: sync.notionDatabaseId, mapping: sync.fieldMapping)
            reminders = try await r
            notionRows = try await n
        } catch {
            ledger.updateTaskSyncRunResult(id: sync.id, status: .error, runAt: now(),
                                           error: Formatters.userMessage(for: error))
            Log.sync.error("Task sync fetch failed: \(Formatters.userMessage(for: error), privacy: .public)")
            return
        }

        let links = ledger.taskLinks(forSyncId: sync.id)
        let plan = TaskSyncEngine.plan(reminders: reminders, notionRows: notionRows,
                                       links: links, rules: sync.activeRules)

        // 2) Execute the plan, accumulating the next baseline link set.
        var newLinks = plan.unchangedLinks
        var firstError: String?
        var succeeded = 0
        let mapping = sync.fieldMapping

        func note(_ error: Error) {
            if firstError == nil { firstError = Formatters.userMessage(for: error) }
            Log.sync.error("Task sync action failed: \(Formatters.userMessage(for: error), privacy: .public)")
        }

        // Unpaired reminders → new Notion rows.
        for item in plan.createInNotion {
            do {
                let pageId = try await notion.createPage(databaseId: sync.notionDatabaseId, task: item.task, mapping: mapping)
                newLinks.append(TaskLink(reminderId: item.reminderId, notionPageId: pageId,
                                         baseline: item.task, baselineSyncedAt: now()))
                succeeded += 1
            } catch { note(error) }
        }

        // Unpaired Notion rows → new reminders.
        for item in plan.createInReminders {
            do {
                let reminderId = try await remindersClient.create(item.task, inList: sync.remindersListId)
                newLinks.append(TaskLink(reminderId: reminderId, notionPageId: item.notionPageId,
                                         baseline: item.task, baselineSyncedAt: now()))
                succeeded += 1
            } catch { note(error) }
        }

        // Pairs + updates: write the merged value to whichever side differs.
        for resolution in plan.matches + plan.updates {
            do {
                if resolution.applyToReminder {
                    try await remindersClient.update(id: resolution.reminderId, to: resolution.merged)
                }
                if resolution.applyToNotion {
                    try await notion.updatePage(pageId: resolution.notionPageId, task: resolution.merged, mapping: mapping)
                }
                newLinks.append(TaskLink(reminderId: resolution.reminderId, notionPageId: resolution.notionPageId,
                                         baseline: resolution.merged, baselineSyncedAt: now()))
                if resolution.applyToReminder || resolution.applyToNotion { succeeded += 1 }
            } catch {
                note(error)
                // Preserve the prior link so the pairing/baseline survives a
                // transient failure and the work retries next cycle.
                if let existing = links.first(where: { $0.reminderId == resolution.reminderId
                    && $0.notionPageId == resolution.notionPageId }) {
                    newLinks.append(existing)
                }
            }
        }

        // Deletions: propagate to the surviving side; drop the link on success.
        for deletion in plan.deletions {
            do {
                if let reminderId = deletion.reminderId { try await remindersClient.delete(id: reminderId) }
                if let pageId = deletion.notionPageId { try await notion.archivePage(pageId: pageId) }
                succeeded += 1
            } catch {
                note(error)
                // Keep the link so the delete retries next cycle.
                if let existing = links.first(where: { $0.reminderId == deletion.reminderId
                    || $0.notionPageId == deletion.notionPageId }) {
                    newLinks.append(existing)
                }
            }
        }

        // 3) Persist the advanced baselines + run status.
        ledger.setTaskLinks(newLinks, forSyncId: sync.id)
        let status: RuleRunStatus = firstError == nil ? .success : (succeeded > 0 ? .partial : .error)
        ledger.updateTaskSyncRunResult(id: sync.id, status: status, runAt: now(), error: firstError)

        let changed = plan.createInNotion.count + plan.createInReminders.count
            + plan.matches.count + plan.updates.count + plan.deletions.count
        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: now(),
            ruleId: sync.id, ruleName: "\(sync.remindersListName) ↔ \(sync.notionDatabaseName)",
            eventType: firstError == nil ? .ruleRunCompleted : .pageFailed,
            rmNotebookName: sync.remindersListName, rmPageId: nil,
            notionPageUrl: nil, durationMs: nil, ocrProvider: nil, errorMessage: firstError))

        Telemetry.capture("task_sync.run", properties: [
            "status": status.rawValue,
            "changed": changed,
            "links": newLinks.count
        ])
    }
}
