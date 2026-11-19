//
//  SyncEditorView+Save.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Turning the editor's draft into stored syncs: save, the per-source save
//  paths, and delete.
//

import Foundation

extension SyncEditorView {
    func save() {
        if isReminders { saveTaskSync(); onClose(); return }
        guard let config = composedConfiguration() else { return }
        let binding = makeBinding(config: config)
        switch source {
        case .kind(.remarkable): saveRemarkable(binding: binding)
        case .kind(.safari):     saveSafari(binding: binding)
        case .kind(.notion):     saveNotionSource(binding: binding)
        case .kind(.x):          saveXSource(binding: binding)
        case .reminders:         break
        }
        onClose()
    }

    func saveTaskSync() {
        guard let taskWorkspaceId, let taskDatabaseId, let taskTitleProperty else { return }
        let mapping = composedTaskMapping(titleProperty: taskTitleProperty)
        let rules = TaskSyncRules(excludedNotionStatuses: excludedStatuses.sorted(),
                                  excludeCompletedReminders: excludeCompletedReminders)
        let provider = TaskProviderConfig.notion(NotionTaskConfig(
            workspaceId: taskWorkspaceId, databaseId: taskDatabaseId,
            databaseName: taskDatabaseName, fieldMapping: mapping))
        // Keep the run history and creation date of the sync being edited.
        let existing = ledger.taskSyncs.first { $0.id == originalTaskSyncId }
        let sync = TaskSync(
            id: originalTaskSyncId ?? UUID().uuidString,
            enabled: isEnabled,
            // The editor is all-lists only — always empty, even when editing an
            // older single-list sync, so the coordinator routes inbound rows by
            // their mapped list instead of dumping them into one list.
            remindersListId: "",
            remindersListName: "All lists",
            provider: provider, rules: rules,
            createdAt: existing?.createdAt ?? Date(),
            lastRunAt: existing?.lastRunAt,
            lastRunStatus: existing?.lastRunStatus ?? .neverRun,
            lastRunError: existing?.lastRunError)
        ledger.upsertTaskSync(sync)
    }

    /// Folds the dynamic mapping rows + the auto title column into a TaskFieldMapping.
    func composedTaskMapping(titleProperty: String) -> TaskFieldMapping {
        func column(_ field: ReminderField) -> String? {
            guard let c = mapRows.first(where: { $0.field == field })?.column, !c.isEmpty else { return nil }
            return c
        }
        let status = column(.status)
        let priority = column(.priority)
        let list = column(.list)
        return TaskFieldMapping(
            titleProperty: titleProperty,
            dueDateProperty: column(.due),
            statusProperty: status,
            statusPropertyType: status.flatMap(columnType),
            statusDoneValue: status == nil ? nil : inferredStatusValue(matching: ["done", "complete", "closed", "finish"]),
            statusNotDoneValue: status == nil ? nil : inferredStatusValue(matching: ["to do", "to-do", "todo", "not started", "backlog", "open", "new", "inbox"]),
            notesProperty: column(.notes),
            priorityProperty: priority,
            priorityPropertyType: priority.flatMap(columnType),
            categoryProperty: list,
            categoryPropertyType: list.flatMap(columnType))
    }

    /// Expands a stored mapping back into editor rows (title is implicit, so it's
    /// not a row). Order: List, Due, Status, Notes, Priority.
    static func rows(from mapping: TaskFieldMapping) -> [TaskMapRow] {
        var rows: [TaskMapRow] = []
        if let c = mapping.categoryProperty { rows.append(TaskMapRow(field: .list, column: c)) }
        if let c = mapping.dueDateProperty  { rows.append(TaskMapRow(field: .due, column: c)) }
        if let c = mapping.statusProperty   { rows.append(TaskMapRow(field: .status, column: c)) }
        if let c = mapping.notesProperty    { rows.append(TaskMapRow(field: .notes, column: c)) }
        if let c = mapping.priorityProperty { rows.append(TaskMapRow(field: .priority, column: c)) }
        return rows
    }

    func makeBinding(config: DestinationConfiguration) -> DestinationBinding {
        DestinationBinding(
            id: existingBinding?.id ?? UUID().uuidString,
            enabled: isEnabled,
            configuration: config,
            createdAt: existingBinding?.createdAt ?? Date(),
            lastRunAt: existingBinding?.lastRunAt,
            lastRunStatus: existingBinding?.lastRunStatus ?? .neverRun,
            lastRunPagesSynced: existingBinding?.lastRunPagesSynced ?? 0,
            lastRunError: existingBinding?.lastRunError,
            ocrModeOverride: sourceKind == .remarkable ? ocrMode : nil,
            titleStrategyOverride: sourceKind == .remarkable ? titleStrategy : nil,
            requiredTags: requiredTags.isEmpty ? nil : requiredTags.sorted()
        )
    }

    func saveRemarkable(binding: DestinationBinding) {
        guard let folder else { return }
        if let origRuleId = originalRuleId, let origBindingId = originalBindingId {
            let sameFolder = ledger.rule(forNotebookId: folder.id)?.id == origRuleId
            if sameFolder {
                applyRuleLevel(folderId: folder.id)
                ledger.updateBinding(ruleId: origRuleId, binding: binding)
                return
            }
            ledger.removeBinding(ruleId: origRuleId, bindingId: origBindingId)
            if let old = ledger.rules.first(where: { $0.id == origRuleId }), old.destinations.isEmpty {
                ledger.deleteRule(id: origRuleId)
            }
        }
        addBinding(to: folder, binding)
    }

    func saveSafari(binding: DestinationBinding) {
        guard let scopeId = safariScopeId else { return }
        let source = SourceConfiguration.safari(SafariSourceConfig(folderId: scopeId, folderName: safariScopeName))
        if let origRuleId = originalRuleId {
            if var rule = ledger.rules.first(where: { $0.id == origRuleId }) {
                rule.source = source
                ledger.upsertRule(rule)
            }
            ledger.updateBinding(ruleId: origRuleId, binding: binding)
        } else {
            var rule = SyncRule(source: source)
            rule.destinations = [binding]
            ledger.upsertRule(rule)
        }
    }

    func saveNotionSource(binding: DestinationBinding) {
        guard let workspaceId = notionSourceWorkspaceId,
              let databaseId = notionSourceDatabaseId else { return }
        let source = SourceConfiguration.notion(NotionSourceConfig(
            workspaceId: workspaceId,
            workspaceName: ledger.notionWorkspaces.first(where: { $0.id == workspaceId })?.workspaceName ?? "",
            databaseId: databaseId,
            databaseTitle: notionSourceDatabaseName,
            titleProperty: notionSourceTitleProperty,
            categoryProperty: notionSourceCategoryProperty,
            dateProperty: notionSourceDateProperty))
        if let origRuleId = originalRuleId {
            if var rule = ledger.rules.first(where: { $0.id == origRuleId }) {
                rule.source = source
                ledger.upsertRule(rule)
            }
            ledger.updateBinding(ruleId: origRuleId, binding: binding)
        } else {
            var rule = SyncRule(source: source)
            rule.destinations = [binding]
            ledger.upsertRule(rule)
        }
    }

    func saveXSource(binding: DestinationBinding) {
        guard let account = selectedXAccount else { return }
        let source = SourceConfiguration.x(XSourceConfig(
            accountId: account.id, username: account.handle, stream: xSourceStream))
        if let origRuleId = originalRuleId {
            if var rule = ledger.rules.first(where: { $0.id == origRuleId }) {
                rule.source = source
                ledger.upsertRule(rule)
            }
            ledger.updateBinding(ruleId: origRuleId, binding: binding)
        } else {
            var rule = SyncRule(source: source)
            rule.destinations = [binding]
            ledger.upsertRule(rule)
        }
    }

    func addBinding(to folder: RmFolder, _ binding: DestinationBinding) {
        if let rule = ledger.rule(forNotebookId: folder.id) {
            applyRuleLevel(folderId: folder.id, base: rule)
            ledger.addBinding(ruleId: rule.id, binding: binding)
        } else {
            var rule = SyncRule.new(notebookId: folder.id, notebookName: folder.name)
            rule.updateRemarkable {
                $0.selectedFileIds = selectedFileIds
                $0.pageOrder = pageOrder
                $0.savePdfAttachment = savePdf
            }
            rule.destinations = [binding]
            ledger.upsertRule(rule)
        }
    }

    func applyRuleLevel(folderId: String, base: SyncRule? = nil) {
        guard var rule = base ?? ledger.rule(forNotebookId: folderId) else { return }
        rule.updateRemarkable {
            $0.selectedFileIds = selectedFileIds
            $0.pageOrder = pageOrder
            $0.savePdfAttachment = savePdf
        }
        rule.updatedAt = Date()
        ledger.upsertRule(rule)
    }

    func deleteSync() {
        if let taskId = originalTaskSyncId {
            ledger.removeTaskSync(id: taskId)
            onClose()
            return
        }
        guard let origRuleId = originalRuleId, let origBindingId = originalBindingId else { return }
        ledger.removeBinding(ruleId: origRuleId, bindingId: origBindingId)
        if let old = ledger.rules.first(where: { $0.id == origRuleId }), old.destinations.isEmpty {
            ledger.deleteRule(id: origRuleId)
        }
        onClose()
    }
}
