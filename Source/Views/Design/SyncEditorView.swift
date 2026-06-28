//
//  SyncEditorView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The one place a Sync is created or edited: From a Source, To a Destination,
//  Customize, and How. Most syncs are one-way (a source folder → a write-only
//  destination); a Reminders source paired with a Notion database is two-way,
//  shown with a ⇄ arrow and mapped field-by-field. Both are "just a sync" here.
//

import SwiftUI
import AppKit

enum SyncEditorTarget: Identifiable {
    case new
    case edit(SyncFlow)
    case editTask(TaskSync)
    var id: String {
        switch self {
        case .new:             return "new"
        case .edit(let f):     return f.id
        case .editTask(let s): return "task-" + s.id
        }
    }
}

/// A connected destination account, normalized for the editor's "To" dropdown.
struct ConnectedApp: Identifiable {
    let id: String
    let kind: DestinationKind
    let name: String
    let defaultConfig: DestinationConfiguration
}

extension Ledger {
    var connectedApps: [ConnectedApp] {
        var out: [ConnectedApp] = []
        out += notionWorkspaces.map { ConnectedApp(id: $0.id, kind: .notion, name: $0.workspaceName, defaultConfig: $0.defaultConfiguration) }
        out += linearAccounts.map { ConnectedApp(id: $0.id, kind: .linear, name: $0.name, defaultConfig: $0.defaultConfiguration) }
        out += googleAccounts.map { ConnectedApp(id: $0.id, kind: .googleDocs, name: $0.displayName, defaultConfig: $0.defaultConfiguration) }
        out += markdownTargets.map { ConnectedApp(id: $0.id, kind: .markdownFolder, name: $0.displayName, defaultConfig: .markdownFolder($0.defaultConfiguration)) }
        out += appleNotesTargets.map { ConnectedApp(id: $0.id, kind: .appleNotes, name: "Apple Notes", defaultConfig: $0.defaultConfiguration) }
        out += chromeTargets.map { ConnectedApp(id: $0.id, kind: .chrome, name: $0.displayName, defaultConfig: $0.defaultConfiguration) }
        return out
    }
}

/// What the editor's FROM step is pointed at. Reminders isn't a one-way
/// SourceClind, so it rides alongside the SourceKinds as its own case.
private enum EditorSource: Equatable {
    case kind(SourceKind)
    case reminders
    var id: String { if case .kind(let k) = self { return k.rawValue }; return "reminders" }
}

struct SyncEditorView: View {
    let target: SyncEditorTarget
    @ObservedObject var coordinator: SyncCoordinator
    var onClose: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    // From
    @State private var source: EditorSource = .kind(.remarkable)
    @State private var folder: RmFolder?
    @State private var selectedFileIds: [String]?
    // From — Safari
    @State private var safariScopes: [SourceScope] = []
    @State private var safariScopeId: String?
    @State private var safariScopeName: String = ""
    // From — Notion (database backup). Wired into the editor UI in a later step;
    // these hold the chosen workspace/database and the Category column.
    @State private var notionSourceWorkspaceId: String?
    @State private var notionSourceDatabaseId: String?
    @State private var notionSourceDatabaseName: String = ""
    @State private var notionSourceTitleProperty: String = ""
    @State private var notionSourceCategoryProperty: String = NotionSourceConfig.defaultCategoryProperty
    /// The Notion date column that supplies each note's date. Empty = created_time.
    @State private var notionSourceDateProperty: String = ""
    @State private var notionSourceDatabases: [NotionDestination] = []
    @State private var notionSourceSchema: [NotionDatabaseProperty] = []
    // From — X (one content stream of one connected account)
    @State private var xSourceAccountId: String?
    @State private var xSourceStream: XStream = .bookmarks
    // From — Reminders (two-way)
    @State private var reminderLists: [ReminderList] = []
    @State private var remindersLoading = false
    @State private var reminderListId: String?
    @State private var reminderListName: String = ""
    // To
    @State private var toKind: DestinationKind?
    @State private var toAccountId: String?
    // To — Notion (one-way page/database). The workspace is the chosen destination
    // account, so it lives in toAccountId; only the page/database is picked here.
    @State private var notionDestinations: [NotionDestination] = []
    @State private var notionDestLoading = false
    @State private var notionDestSchema: [NotionDatabaseProperty] = []
    // To — Notion database (two-way)
    @State private var taskWorkspaceId: String?
    @State private var taskDatabases: [NotionDestination] = []
    @State private var taskDatabaseId: String?
    @State private var taskDatabaseName: String = ""
    @State private var taskSchema: [NotionDatabaseProperty] = []
    @State private var mapRows: [TaskMapRow] = []
    @State private var excludedStatuses: Set<String> = []
    @State private var excludeCompletedReminders = false
    @State private var originalTaskSyncId: String?
    // Customize — per-kind destination forms
    @State private var localNotion = NotionFormState()
    @State private var localLinear = LinearFormState()
    @State private var localGoogle = GoogleFormState()
    @State private var localAppleNotes = AppleNotesFormState()
    @State private var localMarkdown = MarkdownFormState()
    @State private var chromeTargetFolder: String = "From Safari"
    @State private var chromeMirrorExactly = false
    // How
    @State private var titleStrategy: TitleStrategy = .firstLineOfOcr
    @State private var ocrMode: OcrMode = .all
    @State private var pageOrder: PageOrder = .chronological
    @State private var requiredTags: [String] = []
    @State private var savePdf = true
    // edit bookkeeping
    @State private var originalRuleId: String?
    @State private var originalBindingId: String?
    @State private var existingBinding: DestinationBinding?
    // scope sheet
    @State private var isChoosingScope = false
    @State private var scopeFiles: [RmFile] = []
    @State private var scopeLoading = false
    // Notion source dry-run preview
    @State private var previewRunning = false
    @State private var previewError: String?

    private let remindersClient: RemindersClient = EventKitRemindersClient()

    private var isReminders: Bool { source == .reminders }
    private var sourceKind: SourceKind? { if case .kind(let k) = source { return k }; return nil }
    private var isEditing: Bool { originalBindingId != nil || originalTaskSyncId != nil }

    private var canSave: Bool {
        guard hasSourceSelected else { return false }
        if isReminders { return taskWorkspaceId != nil && taskDatabaseId != nil && taskTitleProperty != nil }
        return toKind != nil && destinationValid
    }

    private var hasSourceSelected: Bool {
        switch source {
        case .kind(.remarkable): return folder != nil
        case .kind(.safari):     return safariScopeId != nil
        case .kind(.notion):     return notionSourceDatabaseId != nil
        case .kind(.x):          return xSourceAccountId != nil
        case .reminders:         return true   // all lists; no single list to choose
        }
    }

    /// Sources the user can pick from — only the ones they've added.
    private var availableSources: [EditorSource] {
        var out: [EditorSource] = []
        if ledger.remarkableAccount != nil { out.append(.kind(.remarkable)) }
        if ledger.safariConnected { out.append(.kind(.safari)) }
        // A connected Notion workspace can be a backup source (Notion -> notes).
        if !ledger.notionWorkspaces.isEmpty { out.append(.kind(.notion)) }
        if !ledger.xAccounts.isEmpty { out.append(.kind(.x)) }
        if ledger.remindersConnected { out.append(.reminders) }
        return out.isEmpty ? [.kind(.remarkable)] : out
    }

    /// The X account currently chosen in the FROM step, defaulting to the first.
    private var selectedXAccount: XAccount? {
        ledger.xAccounts.first { $0.id == xSourceAccountId } ?? ledger.xAccounts.first
    }

    /// The streams the chosen X account opted into (and thus has scopes for).
    private var xSourceStreams: [XStream] {
        selectedXAccount?.selectedStreams ?? XStream.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fromStep
                    if isReminders {
                        notionDatabaseStep
                        if taskDatabaseId != nil { mapStep; filterStep }
                    } else {
                        toStep
                        if showCustomize { customizeStep }
                        if sourceKind == .remarkable { howStep }
                    }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 680, height: 640)
        .background(theme.surface)
        .environment(\.theme, theme)
        .onAppear(perform: load)
        .sheet(isPresented: $isChoosingScope) { scopeSheet }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "Edit sync" : "New sync").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.foreground)
                Text(isReminders ? "A Reminders list and a Notion database, kept in sync both ways."
                                 : "From a source, to a destination, synced how.")
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
            if let previewError {
                Text(previewError).font(.system(size: 11)).foregroundStyle(theme.destructive).lineLimit(1)
            }
            Spacer()
            // Dry run: read Notion + the chosen destination, show what a first sync
            // would do, write nothing. Supported for the adopting destinations.
            if sourceKind == .notion, notionSourceDatabaseId != nil,
               toKind == .appleNotes || toKind == .markdownFolder {
                PillButton(title: previewRunning ? "Generating…" : "Preview (no writes)",
                           systemImage: previewRunning ? nil : "eye",
                           filled: false,
                           action: previewNotionSource)
                    .opacity(previewRunning ? 0.5 : 1).disabled(previewRunning)
            }
            PillButton(title: "Cancel", filled: false, action: onClose)
            PillButton(title: "Save sync", action: save).opacity(canSave ? 1 : 0.5).disabled(!canSave)
        }
        .padding(20)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
        .background(theme.background)
    }

    /// Generates the read-only dry-run report for the configured Notion source and
    /// opens it. Uses the Apple Notes destination's folder (or "Notes") as the
    /// fallback notebook for uncategorized pages.
    private func previewNotionSource() {
        guard let workspaceId = notionSourceWorkspaceId, let databaseId = notionSourceDatabaseId else { return }
        let config = NotionSourceConfig(
            workspaceId: workspaceId,
            workspaceName: ledger.notionWorkspaces.first(where: { $0.id == workspaceId })?.workspaceName ?? "",
            databaseId: databaseId,
            databaseTitle: notionSourceDatabaseName,
            titleProperty: notionSourceTitleProperty,
            categoryProperty: notionSourceCategoryProperty)
        let destination = toKind
        let markdownConfig = MarkdownFolderDestinationConfig(
            folderPath: localMarkdown.folderPath,
            fileNameTemplate: localMarkdown.fileNameTemplate.isEmpty ? "{date}-{title}" : localMarkdown.fileNameTemplate,
            includeFrontmatter: localMarkdown.frontmatterMode != .none,
            frontmatterMode: localMarkdown.frontmatterMode)
        let fallback = localAppleNotes.folderName.isEmpty ? "Notes" : localAppleNotes.folderName
        previewRunning = true
        previewError = nil
        Task {
            do {
                let url: URL
                switch destination {
                case .markdownFolder:
                    url = try await NotionMarkdownPreview.generate(source: config, config: markdownConfig)
                default:   // .appleNotes
                    url = try await NotionAppleNotesPreview.generate(source: config, fallbackNotebook: fallback)
                }
                await MainActor.run {
                    previewRunning = false
                    NSWorkspace.shared.open(url)
                }
            } catch {
                let message = Formatters.userMessage(for: error)
                await MainActor.run { previewRunning = false; previewError = message }
            }
        }
    }

    // MARK: From

    private var fromStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("FROM", "which source")
            if availableSources.count > 1 {
                CustomDropdown(
                    options: availableSources.map { DropdownOption(id: $0.id, icon: sourceMenuIcon($0), title: sourceLabel($0)) },
                    selectedId: source.id,
                    placeholder: "Choose a Source",
                    placeholderIcon: AnyView(placeholderSourceIcon),
                    onSelect: { id in selectSource(forId: id) }
                )
            }
            switch source {
            case .kind(.remarkable): remarkableScopePicker
            case .kind(.safari):     safariScopePicker
            case .kind(.notion):     notionSourceScopePicker
            case .kind(.x):          xSourceScopePicker
            case .reminders:         remindersListPicker
            }
        }
    }

    /// X-as-source picker: the account (when several) and the content stream
    /// (bookmarks / likes / posts) this sync pulls. Each stream is its own
    /// independent sync with its own history.
    private var xSourceScopePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ledger.xAccounts.count > 1 {
                CustomDropdown(
                    options: ledger.xAccounts.map { DropdownOption(id: $0.id, icon: AnyView(SourceIcon(kind: .x, size: 24)), title: $0.handle) },
                    selectedId: xSourceAccountId,
                    placeholder: "Choose an account",
                    placeholderIcon: AnyView(SourceIcon(kind: .x, size: 24)),
                    onSelect: { id in selectXAccount(id) }
                )
            }
            CustomDropdown(
                options: xSourceStreams.map { DropdownOption(id: $0.rawValue, icon: AnyView(SourceIcon(kind: .x, size: 24)), title: $0.label, detail: $0.subtitle) },
                selectedId: xSourceStream.rawValue,
                placeholder: "Choose what to sync",
                placeholderIcon: AnyView(placeholderSourceIcon),
                onSelect: { id in if let stream = XStream(rawValue: id) { xSourceStream = stream } }
            )
        }
    }

    private var remarkableScopePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            CustomDropdown(
                options: ledger.folders.map { DropdownOption(id: $0.id, icon: AnyView(SourceIcon(size: 26)), title: $0.name, detail: "(\($0.pageCount) note\($0.pageCount == 1 ? "" : "s"))") },
                selectedId: folder?.id,
                placeholder: "Choose a folder",
                placeholderIcon: AnyView(placeholderSourceIcon),
                onSelect: { id in if let f = ledger.folders.first(where: { $0.id == id }) { selectFolder(f) } }
            )
            if folder != nil {
                HStack(spacing: 8) {
                    Text(scopeSummary).font(.system(size: 12)).foregroundStyle(theme.muted)
                    Spacer()
                    Button(action: openScope) {
                        Text("Choose notebooks")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var safariScopePicker: some View {
        CustomDropdown(
            options: safariScopes.map { DropdownOption(id: $0.id, icon: AnyView(SourceIcon(kind: .safari, size: 26)), title: "\($0.name) · \($0.itemCount)") },
            selectedId: safariScopeId,
            placeholder: safariScopes.isEmpty ? "Loading bookmarks…" : "Choose a bookmark folder",
            placeholderIcon: AnyView(placeholderSourceIcon),
            onSelect: { id in
                if let scope = safariScopes.first(where: { $0.id == id }) {
                    safariScopeId = scope.id
                    safariScopeName = scope.name
                }
            }
        )
    }

    /// Notion-as-source picker: workspace (when several), database, and the
    /// single-select column whose value becomes the destination folder/notebook.
    private var notionSourceScopePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ledger.notionWorkspaces.count > 1 {
                CustomDropdown(
                    options: ledger.notionWorkspaces.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)), title: $0.workspaceName) },
                    selectedId: notionSourceWorkspaceId,
                    placeholder: "Choose a workspace",
                    placeholderIcon: AnyView(DestinationIcon(kind: .notion, size: 24)),
                    onSelect: { id in selectNotionSourceWorkspace(id) }
                )
            }
            CustomDropdown(
                options: notionSourceDatabases.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)), title: $0.title) },
                selectedId: notionSourceDatabaseId,
                placeholder: notionSourceDatabases.isEmpty ? "Loading databases…" : "Choose a database",
                placeholderIcon: AnyView(placeholderSourceIcon),
                onSelect: { id in selectNotionSourceDatabase(id) }
            )
            if notionSourceDatabaseId != nil {
                HStack(spacing: 8) {
                    Text("Folder column").font(.system(size: 12)).foregroundStyle(theme.tertiary)
                    CustomDropdown(
                        options: notionSourceCategoryColumns.map { DropdownOption(id: $0, icon: AnyView(EmptyView()), title: $0) },
                        selectedId: notionSourceCategoryProperty,
                        placeholder: notionSourceCategoryColumns.isEmpty ? "No select columns" : "Choose a column",
                        placeholderIcon: AnyView(placeholderSourceIcon),
                        onSelect: { id in notionSourceCategoryProperty = id }
                    )
                }
                HStack(spacing: 8) {
                    Text("Note date").font(.system(size: 12)).foregroundStyle(theme.tertiary)
                    CustomDropdown(
                        options: [DropdownOption(id: "", icon: AnyView(EmptyView()), title: "Page created time")]
                            + notionSourceDateColumns.map { DropdownOption(id: $0, icon: AnyView(EmptyView()), title: $0) },
                        selectedId: notionSourceDateProperty,
                        placeholder: "Page created time",
                        placeholderIcon: AnyView(placeholderSourceIcon),
                        onSelect: { id in notionSourceDateProperty = id }
                    )
                }
            }
        }
    }

    /// Single-select-style columns that can drive the folder/notebook split.
    private var notionSourceCategoryColumns: [String] {
        notionSourceSchema.filter { ["select", "status", "multi_select"].contains($0.type) }.map(\.name)
    }

    /// Date columns that can supply the note's original date.
    private var notionSourceDateColumns: [String] {
        notionSourceSchema.filter { $0.type == "date" }.map(\.name)
    }

    private var remindersListPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reminderLists.isEmpty && !remindersLoading {
                HStack(spacing: 8) {
                    Text("Reminders access is needed.").font(.system(size: 11)).foregroundStyle(.orange)
                    Button("Allow access") { grantRemindersAccess() }
                        .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain).foregroundStyle(theme.primary)
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain).foregroundStyle(theme.primary)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var scopeSummary: String {
        guard let ids = selectedFileIds, !ids.isEmpty else { return "Syncing every notebook in this folder" }
        return "Syncing \(ids.count) selected notebook\(ids.count == 1 ? "" : "s")"
    }

    // MARK: To (one-way destination)

    private var toStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("TO", "which destination")
            CustomDropdown(
                options: ledger.connectedApps.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: $0.kind, size: 24)), title: $0.name) },
                selectedId: toAccountId,
                placeholder: ledger.hasAnyDestination ? "Choose a Destination" : "Connect a destination first",
                placeholderIcon: AnyView(placeholderDestIcon),
                onSelect: { id in if let app = ledger.connectedApps.first(where: { $0.id == id }) { selectDestination(app) } }
            )
            // The workspace is already chosen above (the Notion account is the
            // workspace), so pick the page/database right here instead of asking
            // for the workspace again down in Customize.
            if toKind == .notion { notionDestinationPicker }
        }
    }

    /// One-way Notion destination: the page or database to write into. Styled like
    /// the other "To" controls and grouped under the same step.
    private var notionDestinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            CustomDropdown(
                options: notionDestinations.map { dest in
                    DropdownOption(id: dest.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)),
                                   title: dest.icon.map { "\($0) \(dest.title)" } ?? dest.title)
                },
                selectedId: localNotion.destinationId.isEmpty ? nil : localNotion.destinationId,
                placeholder: notionDestLoading ? "Loading pages & databases…" : "Choose a page or database",
                placeholderIcon: AnyView(placeholderDestIcon),
                onSelect: { id in selectNotionDestination(id) }
            )
            if !notionDestLoading && notionDestinations.isEmpty {
                HStack(spacing: 8) {
                    Text("Nothing is shared with Sync Bar yet.").font(.system(size: 11)).foregroundStyle(theme.muted)
                    Button("Reload") { loadNotionDestinations() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.primary)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: To (two-way Notion database)

    private var notionDatabaseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("TO").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(theme.primary)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.primary)
                Text("which Notion database (two-way)").font(.system(size: 12)).foregroundStyle(theme.tertiary)
            }
            if ledger.notionWorkspaces.count > 1 {
                CustomDropdown(
                    options: ledger.notionWorkspaces.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)), title: $0.workspaceName) },
                    selectedId: taskWorkspaceId,
                    placeholder: "Choose a workspace",
                    placeholderIcon: AnyView(DestinationIcon(kind: .notion, size: 24)),
                    onSelect: { id in selectTaskWorkspace(id) }
                )
            }
            CustomDropdown(
                options: taskDatabases.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)), title: $0.title) },
                selectedId: taskDatabaseId,
                placeholder: taskDatabases.isEmpty ? "Loading databases…" : "Choose a database",
                placeholderIcon: AnyView(placeholderDestIcon),
                onSelect: { id in selectTaskDatabase(id) }
            )
        }
    }

    // MARK: Map (two-way fields)

    private var taskTitleProperty: String? { taskSchema.first { $0.type == "title" }?.name }
    /// The Notion column the Status field is mapped to (if any), and its options —
    /// used by the FILTER step and the done/not-done inference.
    private var statusColumn: String { mapRows.first { $0.field == .status }?.column ?? "" }
    private var statusType: String? { taskSchema.first { $0.name == statusColumn }?.type }
    private var statusOptions: [String] { taskSchema.first { $0.name == statusColumn }?.options ?? [] }
    private func columnType(_ name: String) -> String? { taskSchema.first { $0.name == name }?.type }

    private var mapStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("MAP", "pair Reminders fields with Notion columns")
            VStack(alignment: .leading, spacing: 0) {
                mapRow("Title") { lockedFieldLabel(taskTitleProperty ?? "No title column") }
                rowDivider
                VStack(alignment: .leading, spacing: 0) {
                    TaskMappingControl(rows: $mapRows, schema: taskSchema)
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
    }

    // MARK: Filter (statuses to skip, from both tools)

    private var filterStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("FILTER", "skip tasks in these statuses")
            MultiSelectDropdown(
                options: filterOptions,
                selected: filterSelection,
                placeholder: "Don't sync tasks in any status",
                onToggle: toggleFilter)
        }
    }

    /// Statuses across both tools (Reminders' "Completed" + the Notion status
    /// column's options), merged by name, alphabetical, each tagged with a glyph
    /// for where it lives.
    private var filterOptions: [MultiSelectOption] {
        var merged: [String: (display: String, reminders: Bool, notion: Bool)] = [:]
        merged["completed"] = ("Completed", true, false)
        for option in Set(statusOptions).union(excludedStatuses) {
            let key = option.lowercased()
            let existing = merged[key]
            merged[key] = (existing?.display ?? option, existing?.reminders ?? false, true)
        }
        return merged.keys.sorted().map { key in
            let entry = merged[key]!
            return MultiSelectOption(id: key, title: entry.display,
                                     icon: sourceGlyphs(reminders: entry.reminders, notion: entry.notion))
        }
    }

    private var filterSelection: Set<String> {
        var selection = Set<String>()
        if excludeCompletedReminders { selection.insert("completed") }
        for status in excludedStatuses { selection.insert(status.lowercased()) }
        return selection
    }

    private func toggleFilter(_ id: String) {
        let willSelect = !filterSelection.contains(id)
        if id == "completed" { excludeCompletedReminders = willSelect }
        if let notionName = (Set(statusOptions).union(excludedStatuses)).first(where: { $0.lowercased() == id }) {
            if willSelect { excludedStatuses.insert(notionName) } else { excludedStatuses.remove(notionName) }
        }
    }

    private func sourceGlyphs(reminders: Bool, notion: Bool) -> AnyView {
        AnyView(HStack(spacing: 4) {
            if reminders {
                Image("Reminders").resizable().interpolation(.high).scaledToFit().frame(width: 16, height: 16)
            }
            if notion { DestinationIcon(kind: .notion, size: 16) }
        }.frame(width: 38, alignment: .leading))
    }

    /// Picks the status option that means done / not-done, by matching common
    /// words against the column's options. nil for a checkbox column (no option
    /// needed) or when nothing matches.
    private func inferredStatusValue(matching keywords: [String]) -> String? {
        guard statusType == "status" || statusType == "select" else { return nil }
        return statusOptions.first { option in
            let lowered = option.lowercased()
            return keywords.contains { lowered.contains($0) }
        }
    }

    /// A read-only field rendered at the same metrics as the editable dropdowns,
    /// so a locked value (the title column) aligns with them instead of floating.
    private func lockedFieldLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.muted).lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).frame(width: 196, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.cardElevated))
    }

    private func mapRow<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }

    // MARK: Icons

    private var placeholderSourceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
            Image(systemName: "folder").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.muted)
        }.frame(width: 26, height: 26)
    }

    private var placeholderDestIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
            Image(systemName: "square.dashed").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.muted)
        }.frame(width: 26, height: 26)
    }

    private var remindersGlyph: some View {
        Image("Reminders").resizable().interpolation(.high).scaledToFit().frame(width: 26, height: 26)
    }

    private func sourceLabel(_ s: EditorSource) -> String {
        switch s { case .kind(let k): return k.label; case .reminders: return "Reminders" }
    }
    private func sourceMenuIcon(_ s: EditorSource) -> AnyView {
        switch s {
        case .kind(let k): return AnyView(SourceIcon(kind: k, size: 26))
        case .reminders:   return AnyView(remindersGlyph)
        }
    }

    // MARK: Customize (inline destination form)

    private var customizeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("CUSTOMIZE", "configure this destination and map fields")
            VStack(alignment: .leading, spacing: 14) { destinationForm }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
    }

    /// Whether the Customize step has anything to show. Notion's only one-way
    /// customization is database column mapping (the page/database itself is now
    /// chosen up in the To step), so it's hidden for page destinations.
    private var showCustomize: Bool {
        guard let toKind else { return false }
        if toKind == .notion {
            return localNotion.destinationType == .database && !localNotion.destinationId.isEmpty
        }
        return true
    }

    @ViewBuilder
    private var destinationForm: some View {
        switch toKind {
        case .notion:         notionMappingForm
        case .linear:         LinearForm(binding: $localLinear, accounts: ledger.linearAccounts)
        case .googleDocs:     GoogleDocsForm(binding: $localGoogle)
        case .appleNotes:     AppleNotesForm(binding: $localAppleNotes, routesByCategory: sourceKind == .notion)
        case .markdownFolder: MarkdownForm(binding: $localMarkdown, targets: ledger.markdownTargets)
        case .chrome:         chromeForm
        case .none:           EmptyView()
        }
    }

    private var chromeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sourceKind == .safari {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exactly match Safari")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                        Text("Safari is the source of truth and sync is unidirectional.")
                            .font(.system(size: 11)).foregroundStyle(theme.tertiary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $chromeMirrorExactly)
                        .labelsHidden().toggleStyle(.switch).tint(theme.primary)
                }
                Text("Chrome must be quit for changes to apply.")
                    .font(.system(size: 11)).foregroundStyle(theme.tertiary)
            } else {
                Text("Add bookmarks to this Chrome folder (under the Bookmarks Bar):")
                    .font(.system(size: 12)).foregroundStyle(theme.muted)
                TextField("From Safari", text: $chromeTargetFolder)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Mapping-only Notion form: the page/database is chosen in the To step, so
    /// Customize just maps note fields onto the database's columns.
    private var notionMappingForm: some View {
        AppCard("Column Mapping") {
            if notionDestSchema.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading database schema…").font(.system(size: 11)).foregroundStyle(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Fill database columns with fields from each note.")
                        .font(.system(size: 11)).foregroundStyle(theme.muted)
                    FieldMappingControl(rows: $localNotion.mappingRows, columns: notionMappingColumns)
                }
            }
        }
    }

    /// Mappable columns (the title column is set from the title strategy, so it's
    /// excluded); select / multi_select / status columns carry their options.
    private var notionMappingColumns: [MappingColumn] {
        let optionTypes: Set<String> = ["select", "multi_select", "status"]
        return notionDestSchema
            .filter { $0.type != "title" }
            .map { property in
                MappingColumn(
                    name: property.name,
                    options: optionTypes.contains(property.type) ? property.options : [],
                    allowsMultiple: property.type == "multi_select"
                )
            }
    }

    // MARK: How

    private var howStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("HOW", "how the sync should work")
            VStack(spacing: 0) {
                optionRow("Title each note") {
                    Segmented(selection: $titleStrategy, options: [(.fileName, "File name"), (.firstLineOfOcr, "First line"), (.template, "Template")])
                }
                rowDivider
                optionRow("Transcribe") {
                    Segmented(selection: $ocrMode, options: [(.all, "All pages"), (.handwrittenOnly, "Handwritten"), (.none, "None")])
                }
                rowDivider
                optionRow("Page order") {
                    Menu {
                        Button("Chronological") { pageOrder = .chronological }
                        Button("Reverse chronological") { pageOrder = .reverseChronological }
                    } label: {
                        HStack(spacing: 8) {
                            Text(pageOrder == .chronological ? "Chronological" : "Reverse")
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.muted)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                rowDivider
                optionRow("Only notes tagged", align: .top) { RequiredTagsControl(requiredTags: $requiredTags) }
                rowDivider
                optionRow("Attach original PDF", subtitle: "also send the page image alongside the text") {
                    Toggle("", isOn: $savePdf).labelsHidden().toggleStyle(.switch).tint(theme.primary)
                }
            }
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
    }

    // MARK: Bits

    private func stepLabel(_ tag: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text(tag).font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(theme.primary)
            Text(desc).font(.system(size: 12)).foregroundStyle(theme.tertiary)
        }
    }

    private var rowDivider: some View { Rectangle().fill(theme.dividerSubtle).frame(height: 1) }

    private func optionRow<Trailing: View>(_ title: String, subtitle: String? = nil, align: VerticalAlignment = .center, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: align, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(theme.tertiary) }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }

    @ViewBuilder private var scopeSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose notebooks").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.foreground)
                    Text(folder.map { "In \($0.name)" } ?? "Pick what syncs from this folder")
                        .font(.system(size: 12.5)).foregroundStyle(theme.muted)
                }
                Spacer()
                Button(action: { isChoosingScope = false }) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.muted)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .padding(20)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }

            NotebookScopePicker(files: scopeFiles, isLoading: scopeLoading, selectedFileIds: selectedFileIds) { selectedFileIds = $0 }

            HStack {
                Spacer()
                PillButton(title: "Done", action: { isChoosingScope = false })
            }
            .padding(20)
            .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
            .background(theme.background)
        }
        .frame(width: 540, height: 560)
        .background(theme.surface)
        .environment(\.theme, theme)
    }

    // MARK: Logic

    private func load() {
        switch target {
        case .new:
            source = availableSources.first ?? .kind(.remarkable)
            if isReminders { loadReminderLists(); taskWorkspaceId = ledger.notionWorkspaces.first?.id; loadTaskDatabases() }
            else if sourceKind == .safari { loadSafariScopes() }
            else if sourceKind == .notion {
                notionSourceWorkspaceId = ledger.notionWorkspaces.first?.id
                loadNotionSourceDatabases()
            }
            else if sourceKind == .x { applyXDefaults() }
        case .edit(let flow):
            loadOneWay(flow)
        case .editTask(let sync):
            loadTask(sync)
        }
    }

    private func loadOneWay(_ flow: SyncFlow) {
        existingBinding = flow.binding
        originalRuleId = flow.ruleId
        originalBindingId = flow.binding.id
        toKind = flow.binding.kind
        requiredTags = flow.requiredTags

        switch flow.rule.source {
        case .remarkable(let cfg):
            source = .kind(.remarkable)
            folder = ledger.folders.first(where: { $0.id == cfg.folderId })
                ?? RmFolder(id: cfg.folderId, name: cfg.folderName, parentFolder: nil, lastModified: Date(), pageCount: 0)
            selectedFileIds = cfg.selectedFileIds
            pageOrder = cfg.pageOrder
            savePdf = cfg.savePdfAttachment
            titleStrategy = flow.titleStrategy
            ocrMode = flow.ocrMode
        case .safari(let cfg):
            source = .kind(.safari)
            safariScopeId = cfg.folderId
            safariScopeName = cfg.folderName
            loadSafariScopes()
        case .notion(let cfg):
            source = .kind(.notion)
            notionSourceWorkspaceId = cfg.workspaceId
            notionSourceDatabaseId = cfg.databaseId
            notionSourceDatabaseName = cfg.databaseTitle
            notionSourceTitleProperty = cfg.titleProperty
            notionSourceCategoryProperty = cfg.categoryProperty
            notionSourceDateProperty = cfg.dateProperty
            loadNotionSourceDatabases()
            loadNotionSourceSchema()
        case .x(let cfg):
            source = .kind(.x)
            xSourceAccountId = cfg.accountId
            xSourceStream = cfg.stream
        }
        loadFormState(from: flow.binding.configuration)
        if toKind == .notion {
            loadNotionDestinations()
            if localNotion.destinationType == .database { loadNotionDestSchema() }
        }
    }

    private func loadTask(_ sync: TaskSync) {
        source = .reminders
        originalTaskSyncId = sync.id
        reminderListId = sync.remindersListId
        reminderListName = sync.remindersListName
        let cfg = sync.provider.notionConfig
        taskWorkspaceId = cfg?.workspaceId
        taskDatabaseId = cfg?.databaseId
        taskDatabaseName = cfg?.databaseName ?? ""
        mapRows = (cfg?.fieldMapping).map(Self.rows(from:)) ?? []
        excludedStatuses = Set(sync.activeRules.excludedNotionStatuses)
        excludeCompletedReminders = sync.activeRules.excludeCompletedReminders
        loadReminderLists()
        loadTaskDatabases()
        loadTaskSchema()
    }

    private func selectSource(forId id: String) {
        let next: EditorSource = (id == "reminders") ? .reminders : (SourceKind(rawValue: id).map { .kind($0) } ?? .kind(.remarkable))
        guard next != source else { return }
        source = next
        switch next {
        case .kind(.remarkable): folder = nil; selectedFileIds = nil
        case .kind(.safari):     safariScopeId = nil; safariScopeName = ""; loadSafariScopes()
        case .kind(.notion):
            notionSourceDatabaseId = nil; notionSourceDatabaseName = ""; notionSourceSchema = []
            if notionSourceWorkspaceId == nil { notionSourceWorkspaceId = ledger.notionWorkspaces.first?.id }
            loadNotionSourceDatabases()
        case .kind(.x):
            applyXDefaults()
        case .reminders:
            reminderListId = nil; reminderListName = ""; mapRows = []
            loadReminderLists()
            if taskWorkspaceId == nil { taskWorkspaceId = ledger.notionWorkspaces.first?.id }
            loadTaskDatabases()
        }
    }

    private func loadSafariScopes() {
        Task {
            let scopes = await coordinator.scopes(for: .safari)
            await MainActor.run { safariScopes = scopes }
        }
    }

    // MARK: X source

    /// Picks the first connected X account and a valid stream for it. Streams are
    /// static (no network), so the picker needs no loader.
    private func applyXDefaults() {
        if xSourceAccountId == nil { xSourceAccountId = ledger.xAccounts.first?.id }
        if !xSourceStreams.contains(xSourceStream) {
            xSourceStream = xSourceStreams.first ?? .bookmarks
        }
    }

    private func selectXAccount(_ id: String) {
        guard id != xSourceAccountId else { return }
        xSourceAccountId = id
        // Keep the chosen stream valid for the newly-selected account.
        if !xSourceStreams.contains(xSourceStream) {
            xSourceStream = xSourceStreams.first ?? .bookmarks
        }
    }

    // MARK: Notion source loaders

    private func selectNotionSourceWorkspace(_ id: String) {
        guard id != notionSourceWorkspaceId else { return }
        notionSourceWorkspaceId = id
        notionSourceDatabaseId = nil; notionSourceDatabaseName = ""; notionSourceSchema = []
        loadNotionSourceDatabases()
    }

    private func selectNotionSourceDatabase(_ id: String) {
        notionSourceDatabaseId = id
        notionSourceDatabaseName = notionSourceDatabases.first { $0.id == id }?.title ?? ""
        loadNotionSourceSchema()
    }

    private func loadNotionSourceDatabases() {
        guard let workspaceId = notionSourceWorkspaceId else { return }
        Task {
            let client = NotionClientFactory.make(workspaceId: workspaceId)
            let all = (try? await client.listDestinations(workspaceId: workspaceId)) ?? []
            await MainActor.run { notionSourceDatabases = all.filter { $0.type == .database } }
        }
    }

    private func loadNotionSourceSchema() {
        guard let workspaceId = notionSourceWorkspaceId, let databaseId = notionSourceDatabaseId else { return }
        Task {
            let client = NotionClientFactory.make(workspaceId: workspaceId)
            let props = (try? await client.databaseSchema(destinationId: databaseId, workspaceId: workspaceId)) ?? []
            await MainActor.run {
                notionSourceSchema = props
                notionSourceTitleProperty = props.first { $0.type == "title" }?.name ?? ""
                // Default the folder column to "Category" when present, else the
                // first select-style column, so the common case needs no choice.
                let selectCols = props.filter { ["select", "status", "multi_select"].contains($0.type) }.map(\.name)
                if !selectCols.contains(notionSourceCategoryProperty) {
                    notionSourceCategoryProperty = selectCols.first(where: { $0 == NotionSourceConfig.defaultCategoryProperty })
                        ?? selectCols.first ?? NotionSourceConfig.defaultCategoryProperty
                }
                // Default the note-date column to one holding the original date, if
                // present ("Created Date" / "Creation Date"); else created_time ("").
                let dateCols = props.filter { $0.type == "date" }.map(\.name)
                if !dateCols.contains(notionSourceDateProperty) {
                    notionSourceDateProperty = dateCols.first(where: { ["Created Date", "Creation Date"].contains($0) }) ?? ""
                }
            }
        }
    }

    private func loadReminderLists() {
        remindersLoading = true
        Task {
            // Each ad-hoc/dev build is a new identity to TCC, so the prior grant
            // may be gone — ask if we don't already have access, then fetch.
            if !remindersClient.authorizationGranted() {
                _ = await remindersClient.requestAccess()
            }
            let lists = await remindersClient.lists()
            await MainActor.run { reminderLists = lists; remindersLoading = false }
        }
    }

    /// Re-request Reminders access from the inline prompt and reload.
    private func grantRemindersAccess() { loadReminderLists() }

    private func selectTaskWorkspace(_ id: String) {
        guard id != taskWorkspaceId else { return }
        taskWorkspaceId = id
        taskDatabaseId = nil; taskDatabaseName = ""; taskSchema = []
        loadTaskDatabases()
    }

    private func loadTaskDatabases() {
        guard let taskWorkspaceId else { return }
        Task {
            let client = NotionClientFactory.make(workspaceId: taskWorkspaceId)
            let all = (try? await client.listDestinations(workspaceId: taskWorkspaceId)) ?? []
            await MainActor.run { taskDatabases = all.filter { $0.type == .database } }
        }
    }

    private func selectTaskDatabase(_ id: String) {
        taskDatabaseId = id
        taskDatabaseName = taskDatabases.first { $0.id == id }?.title ?? ""
        mapRows = []; excludedStatuses = []
        loadTaskSchema()
    }

    private func loadTaskSchema() {
        guard let taskWorkspaceId, let taskDatabaseId else { return }
        Task {
            let client = NotionClientFactory.make(workspaceId: taskWorkspaceId)
            let props = (try? await client.databaseSchema(destinationId: taskDatabaseId, workspaceId: taskWorkspaceId)) ?? []
            await MainActor.run { taskSchema = props }
        }
    }

    private func loadNotionDestinations() {
        guard let id = toAccountId else { return }
        notionDestLoading = true
        Task {
            let client = NotionClientFactory.make(workspaceId: id)
            let all = (try? await client.listDestinations(workspaceId: id)) ?? []
            await MainActor.run { notionDestinations = all; notionDestLoading = false }
        }
    }

    private func selectNotionDestination(_ id: String) {
        guard let dest = notionDestinations.first(where: { $0.id == id }) else { return }
        localNotion.destinationId = dest.id
        localNotion.destinationType = dest.type
        localNotion.destinationTitle = dest.title
        localNotion.mappingRows = []
        notionDestSchema = []
        if dest.type == .database { loadNotionDestSchema() }
    }

    private func loadNotionDestSchema() {
        guard let id = toAccountId, !localNotion.destinationId.isEmpty else { return }
        let destinationId = localNotion.destinationId
        Task {
            let client = NotionClientFactory.make(workspaceId: id)
            let props = (try? await client.databaseSchema(destinationId: destinationId, workspaceId: id)) ?? []
            await MainActor.run { notionDestSchema = props }
        }
    }

    private func loadFormState(from configuration: DestinationConfiguration) {
        switch configuration {
        case .notion(let cfg):
            toAccountId = cfg.workspaceId
            localNotion = NotionFormState(workspaceId: cfg.workspaceId, destinationId: cfg.destinationId,
                                          destinationType: cfg.destinationType, destinationTitle: cfg.destinationTitle,
                                          mappingRows: NotionFormState.mappingRows(from: cfg.propertyMappings))
        case .linear(let cfg):
            toAccountId = cfg.workspaceId
            localLinear = LinearFormState(workspaceId: cfg.workspaceId, projectId: cfg.projectId ?? "",
                                          projectName: cfg.projectName ?? "", defaultLabel: cfg.defaultLabel ?? "")
        case .googleDocs(let cfg):
            toAccountId = cfg.accountEmail
            localGoogle = GoogleFormState(email: cfg.accountEmail, folderId: cfg.folderId ?? "",
                                          folderName: cfg.folderName ?? "", appendMode: cfg.appendMode)
        case .appleNotes(let cfg):
            toAccountId = ledger.appleNotesTargets.first?.id
            localAppleNotes = AppleNotesFormState(folderName: cfg.folderName)
        case .markdownFolder(let cfg):
            toAccountId = ledger.markdownTargets.first?.id
            localMarkdown = MarkdownFormState(folderPath: cfg.folderPath, fileNameTemplate: cfg.fileNameTemplate,
                                              includeFrontmatter: cfg.includeFrontmatter,
                                              frontmatterMode: cfg.effectiveFrontmatter)
        case .chrome(let cfg):
            toAccountId = ledger.chromeTargets.first?.id
            chromeTargetFolder = cfg.targetFolderPath.count > 1 ? (cfg.targetFolderPath.last ?? "") : ""
            chromeMirrorExactly = cfg.mirrorExactly
        }
    }

    private func selectFolder(_ f: RmFolder) { folder = f; selectedFileIds = nil }

    private func selectDestination(_ app: ConnectedApp) {
        toKind = app.kind
        toAccountId = app.id
        switch app.kind {
        case .notion:
            localNotion = NotionFormState(workspaceId: app.id)
            notionDestinations = []; notionDestSchema = []
            loadNotionDestinations()
        case .linear:     localLinear = LinearFormState(workspaceId: app.id)
        case .googleDocs: localGoogle = GoogleFormState(email: app.id)
        case .appleNotes: localAppleNotes = AppleNotesFormState()
        case .markdownFolder:
            if case .markdownFolder(let cfg) = app.defaultConfig {
                localMarkdown = MarkdownFormState(folderPath: cfg.folderPath, fileNameTemplate: cfg.fileNameTemplate, includeFrontmatter: cfg.includeFrontmatter)
            }
            // A Notion backup defaults to a dated filename and full frontmatter so
            // it mirrors the Python tool out of the box.
            if sourceKind == .notion {
                localMarkdown.fileNameTemplate = "{date}-{title}"
                localMarkdown.frontmatterMode = .all
            }
        case .chrome:
            break
        }
    }

    private var destinationValid: Bool {
        switch toKind {
        case .notion:         return !localNotion.workspaceId.isEmpty && !localNotion.destinationId.isEmpty
        case .linear:         return !localLinear.workspaceId.isEmpty
        case .googleDocs:     return !localGoogle.email.isEmpty
        case .appleNotes:     return !localAppleNotes.folderName.isEmpty
        case .markdownFolder: return !localMarkdown.folderPath.isEmpty
        case .chrome:         return true
        case .none:           return false
        }
    }

    private func composedConfiguration() -> DestinationConfiguration? {
        switch toKind {
        case .notion:
            return .notion(NotionDestinationConfig(
                workspaceId: localNotion.workspaceId, destinationId: localNotion.destinationId,
                destinationType: localNotion.destinationType, destinationTitle: localNotion.destinationTitle,
                propertyMappings: localNotion.destinationType == .database ? NotionFormState.propertyMappings(from: localNotion.mappingRows) : [:]))
        case .linear:
            let team = ledger.linearAccounts.first(where: { $0.id == localLinear.workspaceId })
            return .linear(LinearDestinationConfig(
                workspaceId: localLinear.workspaceId, workspaceName: team?.name ?? "",
                projectId: localLinear.projectId.isEmpty ? nil : localLinear.projectId,
                projectName: localLinear.projectName.isEmpty ? nil : localLinear.projectName,
                defaultLabel: localLinear.defaultLabel.isEmpty ? nil : localLinear.defaultLabel,
                requiredTags: requiredTags.isEmpty ? nil : requiredTags.sorted()))
        case .googleDocs:
            return .googleDocs(GoogleDocsDestinationConfig(
                accountEmail: localGoogle.email, folderId: localGoogle.folderId.isEmpty ? nil : localGoogle.folderId,
                folderName: localGoogle.folderName.isEmpty ? nil : localGoogle.folderName, appendMode: localGoogle.appendMode))
        case .appleNotes:
            return .appleNotes(AppleNotesDestinationConfig(folderName: localAppleNotes.folderName))
        case .markdownFolder:
            return .markdownFolder(MarkdownFolderDestinationConfig(
                folderPath: localMarkdown.folderPath,
                fileNameTemplate: localMarkdown.fileNameTemplate.isEmpty ? "{notebook}-page-{page_n}" : localMarkdown.fileNameTemplate,
                includeFrontmatter: localMarkdown.frontmatterMode != .none,
                frontmatterMode: localMarkdown.frontmatterMode))
        case .chrome:
            let sub = chromeTargetFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            return .chrome(ChromeDestinationConfig(
                profileDirName: ledger.chromeTargets.first?.profileDirName ?? "Default",
                targetFolderPath: sub.isEmpty ? ["Bookmarks Bar"] : ["Bookmarks Bar", sub],
                mirrorExactly: sourceKind == .safari ? chromeMirrorExactly : false))
        case .none: return nil
        }
    }

    private func openScope() {
        guard let folder else { return }
        isChoosingScope = true
        scopeLoading = true
        Task {
            let files = await coordinator.files(inFolder: folder.id)
            await MainActor.run { scopeFiles = files; scopeLoading = false }
        }
    }

    private func save() {
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

    private func saveTaskSync() {
        guard let taskWorkspaceId, let taskDatabaseId, let taskTitleProperty else { return }
        let mapping = composedTaskMapping(titleProperty: taskTitleProperty)
        let rules = TaskSyncRules(excludedNotionStatuses: excludedStatuses.sorted(),
                                  excludeCompletedReminders: excludeCompletedReminders)
        let provider = TaskProviderConfig.notion(NotionTaskConfig(
            workspaceId: taskWorkspaceId, databaseId: taskDatabaseId,
            databaseName: taskDatabaseName, fieldMapping: mapping))
        let sync = TaskSync(
            id: originalTaskSyncId ?? UUID().uuidString,
            // The editor is all-lists only — always empty, even when editing an
            // older single-list sync, so the coordinator routes inbound rows by
            // their mapped list instead of dumping them into one list.
            remindersListId: "",
            remindersListName: "All lists",
            provider: provider, rules: rules)
        ledger.upsertTaskSync(sync)
    }

    /// Folds the dynamic mapping rows + the auto title column into a TaskFieldMapping.
    private func composedTaskMapping(titleProperty: String) -> TaskFieldMapping {
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
    private static func rows(from mapping: TaskFieldMapping) -> [TaskMapRow] {
        var rows: [TaskMapRow] = []
        if let c = mapping.categoryProperty { rows.append(TaskMapRow(field: .list, column: c)) }
        if let c = mapping.dueDateProperty  { rows.append(TaskMapRow(field: .due, column: c)) }
        if let c = mapping.statusProperty   { rows.append(TaskMapRow(field: .status, column: c)) }
        if let c = mapping.notesProperty    { rows.append(TaskMapRow(field: .notes, column: c)) }
        if let c = mapping.priorityProperty { rows.append(TaskMapRow(field: .priority, column: c)) }
        return rows
    }

    private func makeBinding(config: DestinationConfiguration) -> DestinationBinding {
        DestinationBinding(
            id: existingBinding?.id ?? UUID().uuidString,
            enabled: existingBinding?.enabled ?? true,
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

    private func saveRemarkable(binding: DestinationBinding) {
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

    private func saveSafari(binding: DestinationBinding) {
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

    private func saveNotionSource(binding: DestinationBinding) {
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

    private func saveXSource(binding: DestinationBinding) {
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

    private func addBinding(to folder: RmFolder, _ binding: DestinationBinding) {
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

    private func applyRuleLevel(folderId: String, base: SyncRule? = nil) {
        guard var rule = base ?? ledger.rule(forNotebookId: folderId) else { return }
        rule.updateRemarkable {
            $0.selectedFileIds = selectedFileIds
            $0.pageOrder = pageOrder
            $0.savePdfAttachment = savePdf
        }
        rule.updatedAt = Date()
        ledger.upsertRule(rule)
    }

    private func deleteSync() {
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

// MARK: - Segmented control

struct Segmented<T: Equatable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = selection == opt.0
                Button(action: { selection = opt.0 }) {
                    Text(opt.1)
                        .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? theme.primaryForeground : theme.muted)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? theme.primary : Color.clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.background))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
