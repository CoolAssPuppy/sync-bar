//
//  TaskSyncEditorView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The editor for a two-way sync: a Reminders list <-> a Notion database, with
//  fields mapped to the database's live schema. Unlike SyncEditorView (a one-way
//  Source → Destination flow), both sides are read AND written, so this builds a
//  TaskSync record rather than a rule + binding.
//

import SwiftUI

enum TaskSyncEditorTarget: Identifiable {
    case new
    case edit(TaskSync)
    var id: String { if case .edit(let s) = self { return s.id }; return "new-task-sync" }
}

struct TaskSyncEditorView: View {
    let target: TaskSyncEditorTarget
    var onClose: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    // From — Reminders
    @State private var reminderLists: [ReminderList] = []
    @State private var reminderListId: String?
    @State private var reminderListName: String = ""
    // To — Notion
    @State private var workspaceId: String?
    @State private var databases: [NotionDestination] = []
    @State private var databasesLoading = false
    @State private var databaseId: String?
    @State private var databaseName: String = ""
    // Map
    @State private var schema: [NotionDatabaseProperty] = []
    @State private var schemaLoading = false
    @State private var dueProperty: String = ""
    @State private var statusProperty: String = ""
    @State private var doneValue: String = ""
    @State private var notDoneValue: String = ""
    @State private var notesProperty: String = ""
    // edit bookkeeping
    @State private var originalId: String?

    private let reminders: RemindersClient = EventKitRemindersClient()

    private var isEditing: Bool { originalId != nil }
    private var titleProperty: String? { schema.first { $0.type == "title" }?.name }
    private var canSave: Bool {
        reminderListId != nil && workspaceId != nil && databaseId != nil && titleProperty != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fromStep
                    toStep
                    if databaseId != nil { mapStep }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 680, height: 640)
        .background(theme.surface)
        .environment(\.theme, theme)
        .onAppear(perform: load)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "Edit two-way sync" : "New two-way sync")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.foreground)
                Text("Keep a Reminders list and a Notion database in sync, both ways.")
                    .font(.system(size: 12.5)).foregroundStyle(theme.muted)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.muted)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(20)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button(action: deleteSync) {
                    Text("Delete sync").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.destructive)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.destructive.opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Spacer()
            PillButton(title: "Cancel", filled: false, action: onClose)
            PillButton(title: "Save sync", action: save).opacity(canSave ? 1 : 0.5).disabled(!canSave)
        }
        .padding(20)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
        .background(theme.background)
    }

    // MARK: From (Reminders list)

    private var fromStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("REMINDERS", "which list")
            CustomDropdown(
                options: reminderLists.map { DropdownOption(id: $0.id, icon: AnyView(glyph("checklist")), title: $0.name) },
                selectedId: reminderListId,
                placeholder: reminderLists.isEmpty ? "No Reminders lists found" : "Choose a list",
                placeholderIcon: AnyView(glyph("checklist")),
                onSelect: { id in
                    reminderListId = id
                    reminderListName = reminderLists.first { $0.id == id }?.name ?? ""
                })
            if reminderLists.isEmpty {
                Text("Grant Reminders access in Connections, then reopen this editor.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: To (Notion workspace + database)

    private var toStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("NOTION", "which database")
            if ledger.notionWorkspaces.count > 1 {
                CustomDropdown(
                    options: ledger.notionWorkspaces.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)), title: $0.workspaceName) },
                    selectedId: workspaceId,
                    placeholder: "Choose a workspace",
                    placeholderIcon: AnyView(DestinationIcon(kind: .notion, size: 24)),
                    onSelect: { id in selectWorkspace(id) })
            }
            CustomDropdown(
                options: databases.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)), title: $0.title) },
                selectedId: databaseId,
                placeholder: databasesLoading ? "Loading databases…" : (databases.isEmpty ? "No databases found" : "Choose a database"),
                placeholderIcon: AnyView(DestinationIcon(kind: .notion, size: 24)),
                onSelect: { id in selectDatabase(id) })
        }
    }

    // MARK: Map fields

    private var mapStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("MAP", "match Notion columns to task fields")
            VStack(spacing: 0) {
                mapRow("Title") {
                    Text(titleProperty ?? (schemaLoading ? "Loading…" : "No title column"))
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                }
                rowDivider
                mapRow("Due date") {
                    propertyMenu(selection: $dueProperty, options: propertyNames(ofTypes: ["date"]))
                }
                rowDivider
                mapRow("Status") {
                    propertyMenu(selection: $statusProperty, options: propertyNames(ofTypes: ["status", "select", "checkbox"]),
                                 onChange: { _ in doneValue = ""; notDoneValue = "" })
                }
                if needsStatusOptions {
                    rowDivider
                    mapRow("Done means") { optionMenu(selection: $doneValue, options: statusOptions) }
                    rowDivider
                    mapRow("Not done means") { optionMenu(selection: $notDoneValue, options: statusOptions, noneLabel: "Leave as-is") }
                }
                rowDivider
                mapRow("Notes") {
                    propertyMenu(selection: $notesProperty, options: propertyNames(ofTypes: ["rich_text"]))
                }
            }
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            Text("Conflicts resolve to the most recently edited side. Deletes propagate both ways.")
                .font(.system(size: 11)).foregroundStyle(theme.tertiary)
        }
    }

    private var statusType: String? { schema.first { $0.name == statusProperty }?.type }
    private var statusOptions: [String] { schema.first { $0.name == statusProperty }?.options ?? [] }
    private var needsStatusOptions: Bool { statusType == "status" || statusType == "select" }

    private func propertyNames(ofTypes types: [String]) -> [String] {
        schema.filter { types.contains($0.type) }.map(\.name)
    }

    // MARK: Small controls

    private func propertyMenu(selection: Binding<String>, options: [String], onChange: ((String) -> Void)? = nil) -> some View {
        Menu {
            Button("None") { selection.wrappedValue = ""; onChange?("") }
            ForEach(options, id: \.self) { name in
                Button(name) { selection.wrappedValue = name; onChange?(name) }
            }
        } label: { menuLabel(selection.wrappedValue.isEmpty ? "None" : selection.wrappedValue) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func optionMenu(selection: Binding<String>, options: [String], noneLabel: String = "None") -> some View {
        Menu {
            Button(noneLabel) { selection.wrappedValue = "" }
            ForEach(options, id: \.self) { name in
                Button(name) { selection.wrappedValue = name }
            }
        } label: { menuLabel(selection.wrappedValue.isEmpty ? noneLabel : selection.wrappedValue) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foregroundSoft).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    private func mapRow<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }

    private var rowDivider: some View { Rectangle().fill(theme.dividerSubtle).frame(height: 1) }

    private func stepLabel(_ tag: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text(tag).font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(theme.primary)
            Text(desc).font(.system(size: 12)).foregroundStyle(theme.tertiary)
        }
    }

    private func glyph(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
            Image(systemName: systemName).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.primary)
        }.frame(width: 26, height: 26)
    }

    // MARK: Logic

    private func load() {
        loadReminderLists()
        if case .edit(let sync) = target {
            originalId = sync.id
            reminderListId = sync.remindersListId
            reminderListName = sync.remindersListName
            workspaceId = sync.notionWorkspaceId
            databaseId = sync.notionDatabaseId
            databaseName = sync.notionDatabaseName
            dueProperty = sync.fieldMapping.dueDateProperty ?? ""
            statusProperty = sync.fieldMapping.statusProperty ?? ""
            doneValue = sync.fieldMapping.statusDoneValue ?? ""
            notDoneValue = sync.fieldMapping.statusNotDoneValue ?? ""
            notesProperty = sync.fieldMapping.notesProperty ?? ""
            loadDatabases()
            loadSchema()
        } else {
            workspaceId = ledger.notionWorkspaces.first?.id
            loadDatabases()
        }
    }

    private func loadReminderLists() {
        Task {
            let lists = await reminders.lists()
            await MainActor.run { reminderLists = lists }
        }
    }

    private func selectWorkspace(_ id: String) {
        guard id != workspaceId else { return }
        workspaceId = id
        databaseId = nil; databaseName = ""; schema = []
        loadDatabases()
    }

    private func loadDatabases() {
        guard let workspaceId else { return }
        databasesLoading = true
        Task {
            let client = NotionClientFactory.make(workspaceId: workspaceId)
            let all = (try? await client.listDestinations(workspaceId: workspaceId)) ?? []
            await MainActor.run {
                databases = all.filter { $0.type == .database }
                databasesLoading = false
            }
        }
    }

    private func selectDatabase(_ id: String) {
        databaseId = id
        databaseName = databases.first { $0.id == id }?.title ?? ""
        // A fresh database means a fresh schema and mapping.
        dueProperty = ""; statusProperty = ""; doneValue = ""; notDoneValue = ""; notesProperty = ""
        loadSchema()
    }

    private func loadSchema() {
        guard let workspaceId, let databaseId else { return }
        schemaLoading = true
        Task {
            let client = NotionClientFactory.make(workspaceId: workspaceId)
            let props = (try? await client.databaseSchema(destinationId: databaseId, workspaceId: workspaceId)) ?? []
            await MainActor.run { schema = props; schemaLoading = false }
        }
    }

    private func save() {
        guard let reminderListId, let workspaceId, let databaseId, let titleProperty else { return }
        let mapping = TaskFieldMapping(
            titleProperty: titleProperty,
            dueDateProperty: dueProperty.isEmpty ? nil : dueProperty,
            statusProperty: statusProperty.isEmpty ? nil : statusProperty,
            statusPropertyType: statusProperty.isEmpty ? nil : statusType,
            statusDoneValue: doneValue.isEmpty ? nil : doneValue,
            statusNotDoneValue: notDoneValue.isEmpty ? nil : notDoneValue,
            notesProperty: notesProperty.isEmpty ? nil : notesProperty)
        let sync = TaskSync(
            id: originalId ?? UUID().uuidString,
            remindersListId: reminderListId, remindersListName: reminderListName,
            notionWorkspaceId: workspaceId, notionDatabaseId: databaseId, notionDatabaseName: databaseName,
            fieldMapping: mapping)
        ledger.upsertTaskSync(sync)
        onClose()
    }

    private func deleteSync() {
        if let originalId { ledger.removeTaskSync(id: originalId) }
        onClose()
    }
}
