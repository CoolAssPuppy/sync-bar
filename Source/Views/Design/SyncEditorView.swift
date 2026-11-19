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

/// What the editor's FROM step is pointed at. Reminders isn't a one-way
/// SourceClind, so it rides alongside the SourceKinds as its own case.
enum EditorSource: Equatable {
    case kind(SourceKind)
    case reminders
    var id: String { if case .kind(let k) = self { return k.rawValue }; return "reminders" }
}

struct SyncEditorView: View {
    let target: SyncEditorTarget
    @ObservedObject var coordinator: SyncCoordinator
    var onClose: () -> Void

    @ObservedObject var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    // From
    @State var source: EditorSource = .kind(.remarkable)
    @State var folder: RmFolder?
    @State var selectedFileIds: [String]?
    // From — Safari
    @State var safariScopes: [SourceScope] = []
    @State var safariScopeId: String?
    @State var safariScopeName: String = ""
    // From — Notion (database backup). Wired into the editor UI in a later step;
    // these hold the chosen workspace/database and the Category column.
    @State var notionSourceWorkspaceId: String?
    @State var notionSourceDatabaseId: String?
    @State var notionSourceDatabaseName: String = ""
    @State var notionSourceTitleProperty: String = ""
    @State var notionSourceCategoryProperty: String = NotionSourceConfig.defaultCategoryProperty
    /// The Notion date column that supplies each note's date. Empty = created_time.
    @State var notionSourceDateProperty: String = ""
    @State var notionSourceDatabases: [NotionDestination] = []
    @State var notionSourceSchema: [NotionDatabaseProperty] = []
    // From — X (one content stream of one connected account)
    @State var xSourceAccountId: String?
    @State var xSourceStream: XStream = .bookmarks
    // From — Reminders (two-way)
    @State var reminderLists: [ReminderList] = []
    @State var remindersLoading = false
    @State var reminderListId: String?
    @State var reminderListName: String = ""
    // To
    @State var toKind: DestinationKind?
    @State var toAccountId: String?
    // To — Notion (one-way page/database). The workspace is the chosen destination
    // account, so it lives in toAccountId; only the page/database is picked here.
    @State var notionDestinations: [NotionDestination] = []
    @StateObject var pickers = PickerLoadTracker()
    @State var notionDestSchema: [NotionDatabaseProperty] = []
    @State var notionDestSchemaLoading = false
    @State var notionDestSchemaError: String?
    // To — Notion database (two-way)
    @State var taskWorkspaceId: String?
    @State var taskDatabases: [NotionDestination] = []
    @State var taskDatabaseId: String?
    @State var taskDatabaseName: String = ""
    @State var taskSchema: [NotionDatabaseProperty] = []
    @State var mapRows: [TaskMapRow] = []
    @State var excludedStatuses: Set<String> = []
    @State var excludeCompletedReminders = false
    @State var originalTaskSyncId: String?
    // Customize — per-kind destination forms
    @State var localNotion = NotionFormState()
    @State var localLinear = LinearFormState()
    @State var localGoogle = GoogleFormState()
    @State var localAppleNotes = AppleNotesFormState()
    @State var localMarkdown = MarkdownFormState()
    @State var chromeTargetFolder: String = "From Safari"
    @State var chromeMirrorExactly = false
    // How
    @State var titleStrategy: TitleStrategy = .firstLineOfOcr
    @State var ocrMode: OcrMode = .all
    @State var pageOrder: PageOrder = .chronological
    @State var requiredTags: [String] = []
    @State var savePdf = true
    // edit bookkeeping
    @State var originalRuleId: String?
    @State var originalBindingId: String?
    @State var existingBinding: DestinationBinding?
    // scope sheet
    @State var isChoosingScope = false
    @State var scopeFiles: [RmFile] = []
    @State var scopeLoading = false
    // Notion source dry-run preview
    @State var previewRunning = false
    @State var previewError: String?
    // Safety: on/off, unsaved-changes and delete confirmations
    @State var isEnabled = true
    @State var baseline: String?
    @State var baselineConfig: DestinationConfiguration?
    @State var isConfirmingDiscard = false
    @State var isConfirmingDelete = false

    private let remindersClient: RemindersClient = EventKitRemindersClient()

    var isReminders: Bool { source == .reminders }
    var sourceKind: SourceKind? { if case .kind(let k) = source { return k }; return nil }
    var isEditing: Bool { originalBindingId != nil || originalTaskSyncId != nil }

    var canSave: Bool {
        guard hasSourceSelected else { return false }
        if isReminders { return taskWorkspaceId != nil && taskDatabaseId != nil && taskTitleProperty != nil }
        return toKind != nil && destinationValid
    }

    var hasSourceSelected: Bool {
        switch source {
        case .kind(.remarkable): return folder != nil
        case .kind(.safari):     return safariScopeId != nil
        case .kind(.notion):     return notionSourceDatabaseId != nil
        case .kind(.x):          return xSourceAccountId != nil
        case .reminders:         return true   // all lists; no single list to choose
        }
    }

    /// Sources the user can pick from — only the ones they've added. Falls back to
    /// reMarkable so the "From" step always has something to render; the editor is
    /// unreachable with no source anyway.
    var availableSources: [EditorSource] {
        var out = ledger.connectedSourceKinds.map(EditorSource.kind)
        if ledger.remindersConnected { out.append(.reminders) }
        return out.isEmpty ? [.kind(.remarkable)] : out
    }

    /// The X account currently chosen in the FROM step, defaulting to the first.
    var selectedXAccount: XAccount? {
        ledger.xAccounts.first { $0.id == xSourceAccountId } ?? ledger.xAccounts.first
    }

    /// The streams the chosen X account opted into (and thus has scopes for).
    var xSourceStreams: [XStream] {
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
        .onAppear {
            load()
            // Snapshot after this pass's state writes so "unsaved" means edits.
            DispatchQueue.main.async {
                baseline = draftFingerprint
                baselineConfig = composedConfiguration()
            }
        }
        .sheet(isPresented: $isChoosingScope) { scopeSheet }
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard) {
            Button("Discard", role: .destructive, action: onClose)
        }
        .confirmationDialog("Delete this sync?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive, action: deleteSync)
        } message: {
            Text("Notes it already synced stay where they are.")
        }
    }

    var isDirty: Bool {
        guard baseline != nil else { return false }
        return baseline != draftFingerprint || baselineConfig != composedConfiguration()
    }

    func requestClose() {
        if isDirty { isConfirmingDiscard = true } else { onClose() }
    }

    /// Everything a save would store except the destination settings, which
    /// compare with `==` (their dictionaries print in no fixed order).
    var draftFingerprint: String {
        let rows = mapRows.map { "\($0.field)=\($0.column)" }.joined(separator: ",")
        let parts: [String] = [
            "\(source)", folder?.id ?? "", "\(selectedFileIds ?? [])", safariScopeId ?? "",
            notionSourceWorkspaceId ?? "", notionSourceDatabaseId ?? "", notionSourceCategoryProperty,
            notionSourceDateProperty, xSourceAccountId ?? "", "\(xSourceStream)", "\(toKind as Any)", toAccountId ?? "",
            "\(titleStrategy)", "\(ocrMode)", "\(pageOrder)",
            requiredTags.sorted().joined(separator: ","), "\(savePdf)", "\(isEnabled)",
            taskWorkspaceId ?? "", taskDatabaseId ?? "", rows,
            excludedStatuses.sorted().joined(separator: ","), "\(excludeCompletedReminders)"
        ]
        return parts.joined(separator: "|")
    }

    /// Why Save is unavailable, named so a greyed-out button isn't a mystery.
    var saveBlocker: String? {
        guard !canSave else { return nil }
        if !hasSourceSelected {
            switch source {
            case .kind(.remarkable): return "Choose a folder"
            case .kind(.safari):     return "Choose a bookmark folder"
            case .kind(.notion):     return "Choose a Notion database"
            case .kind(.x):          return "Choose a Twitter account"
            case .reminders:         return "Choose what to sync from"
            }
        }
        if isReminders {
            if taskDatabaseId == nil { return "Choose a Notion database" }
            return "That database has no title column"
        }
        if toKind == nil { return "Choose a destination" }
        return "Finish the destination settings"
    }

    /// Editing where notes go makes the next run rewrite every synced note.
    var rewritesEverything: Bool {
        guard let existing = existingBinding, let config = composedConfiguration() else { return false }
        return !existing.configuration.hasSameSettings(as: config)
    }

    // MARK: Header / footer

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "Edit sync" : "New sync").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.foreground)
            }
            Spacer()
            Button(action: requestClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.muted)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(20)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }

    var footer: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button(action: { isConfirmingDelete = true }) {
                    Text("Delete sync").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.destructive)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.destructive.opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            if isEditing {
                Toggle("Sync on", isOn: $isEnabled)
                    .toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foregroundSoft)
                    .help(isEnabled ? "Turn this sync off" : "Turn this sync on")
            }
            if let footerNote {
                Text(footerNote.text).font(.system(size: 11)).foregroundStyle(footerNote.color).lineLimit(2)
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
                    .disabled(previewRunning)
            }
            PillButton(title: "Cancel", filled: false, action: requestClose)
            PillButton(title: "Save sync", action: save).disabled(!canSave)
        }
        .padding(20)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
        .background(theme.background)
    }

    var footerNote: (text: String, color: Color)? {
        if let previewError { return (previewError, theme.destructive) }
        if let saveBlocker { return (saveBlocker, theme.muted) }
        if rewritesEverything { return ("Saving rewrites every synced note on the next run.", theme.warning) }
        return nil
    }

    /// Generates the read-only dry-run report for the configured Notion source and
    /// opens it. Uses the Apple Notes destination's folder (or "Notes") as the
    /// fallback notebook for uncategorized pages.
    func previewNotionSource() {
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
        Task { @MainActor in
            do {
                let url = try await NotionSourcePreview.generate(destination: destination, source: config,
                                                                 markdown: markdownConfig, fallbackNotebook: fallback)
                NSWorkspace.shared.open(url)
            } catch {
                previewError = Formatters.userMessage(for: error)
            }
            previewRunning = false
        }
    }

    // MARK: From

    var fromStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("FROM")
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
    var xSourceScopePicker: some View {
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

    var remarkableScopePicker: some View {
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

    var safariScopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            CustomDropdown(
                options: safariScopes.map { DropdownOption(id: $0.id, icon: AnyView(SourceIcon(kind: .safari, size: 26)), title: "\($0.name) · \($0.itemCount)") },
                selectedId: safariScopeId,
                placeholder: pickers.placeholder(.safariFolders, isEmpty: safariScopes.isEmpty,
                                         ready: "Choose a bookmark folder", empty: "No bookmark folders"),
                placeholderIcon: AnyView(placeholderSourceIcon),
                onSelect: { id in
                    if let scope = safariScopes.first(where: { $0.id == id }) {
                        safariScopeId = scope.id
                        safariScopeName = scope.name
                    }
                }
            )
            pickers.errorLine(.safariFolders, retry: loadSafariScopes)
        }
    }

    /// Notion-as-source picker: workspace (when several), database, and the
    /// single-select column whose value becomes the destination folder/notebook.
    var notionSourceScopePicker: some View {
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
                placeholder: pickers.placeholder(.notionSourceDatabases, isEmpty: notionSourceDatabases.isEmpty,
                                         ready: "Choose a database", empty: "No databases shared with Sync Bar"),
                placeholderIcon: AnyView(placeholderSourceIcon),
                onSelect: { id in selectNotionSourceDatabase(id) }
            )
            pickers.errorLine(.notionSourceDatabases, retry: loadNotionSourceDatabases)
            if notionSourceDatabaseId != nil {
                HStack(spacing: 8) {
                    Text("Folder from").font(.system(size: 12)).foregroundStyle(theme.tertiary)
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
    var notionSourceCategoryColumns: [String] {
        notionSourceSchema.filter { ["select", "status", "multi_select"].contains($0.type) }.map(\.name)
    }

    /// Date columns that can supply the note's original date.
    var notionSourceDateColumns: [String] {
        notionSourceSchema.filter { $0.type == "date" }.map(\.name)
    }

    var remindersListPicker: some View {
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

    var scopeSummary: String {
        guard let ids = selectedFileIds, !ids.isEmpty else { return "Syncing every notebook in this folder" }
        return "Syncing \(ids.count) selected notebook\(ids.count == 1 ? "" : "s")"
    }

    // MARK: To (one-way destination)

    var toStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("TO")
            CustomDropdown(
                options: ledger.connectedApps.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: $0.kind, size: 24)), title: $0.name) },
                selectedId: toAccountId,
                placeholder: ledger.hasAnyDestination ? "Choose a destination" : "Connect a destination first",
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
    var notionDestinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            CustomDropdown(
                options: notionDestinations.map { dest in
                    DropdownOption(id: dest.id, icon: AnyView(DestinationIcon(kind: .notion, size: 24)),
                                   title: dest.icon.map { "\($0) \(dest.title)" } ?? dest.title)
                },
                selectedId: localNotion.destinationId.isEmpty ? nil : localNotion.destinationId,
                placeholder: pickers.placeholder(.notionDestinations, isEmpty: notionDestinations.isEmpty,
                                         ready: "Choose a page or database", empty: "Choose a page or database"),
                placeholderIcon: AnyView(placeholderDestIcon),
                onSelect: { id in selectNotionDestination(id) }
            )
            pickers.errorLine(.notionDestinations, retry: loadNotionDestinations)
            if pickers.isSettled(.notionDestinations), notionDestinations.isEmpty {
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

    var notionDatabaseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("TO").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(theme.primary)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.primary)
                Text("Two-way").font(.system(size: 12)).foregroundStyle(theme.tertiary)
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
                placeholder: pickers.placeholder(.notionTaskDatabases, isEmpty: taskDatabases.isEmpty,
                                         ready: "Choose a database", empty: "No databases shared with Sync Bar"),
                placeholderIcon: AnyView(placeholderDestIcon),
                onSelect: { id in selectTaskDatabase(id) }
            )
            pickers.errorLine(.notionTaskDatabases, retry: loadTaskDatabases)
        }
    }

    // MARK: Map (two-way fields)

    var taskTitleProperty: String? { taskSchema.first { $0.type == "title" }?.name }
    /// The Notion column the Status field is mapped to (if any), and its options —
    /// used by the FILTER step and the done/not-done inference.
    var statusColumn: String { mapRows.first { $0.field == .status }?.column ?? "" }
    var statusType: String? { taskSchema.first { $0.name == statusColumn }?.type }
    var statusOptions: [String] { taskSchema.first { $0.name == statusColumn }?.options ?? [] }
    func columnType(_ name: String) -> String? { taskSchema.first { $0.name == name }?.type }

    var mapStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("MAP")
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

    var filterStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("FILTER")
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
    var filterOptions: [MultiSelectOption] {
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

    var filterSelection: Set<String> {
        var selection = Set<String>()
        if excludeCompletedReminders { selection.insert("completed") }
        for status in excludedStatuses { selection.insert(status.lowercased()) }
        return selection
    }

    func toggleFilter(_ id: String) {
        let willSelect = !filterSelection.contains(id)
        if id == "completed" { excludeCompletedReminders = willSelect }
        if let notionName = (Set(statusOptions).union(excludedStatuses)).first(where: { $0.lowercased() == id }) {
            if willSelect { excludedStatuses.insert(notionName) } else { excludedStatuses.remove(notionName) }
        }
    }

    func sourceGlyphs(reminders: Bool, notion: Bool) -> AnyView {
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
    func inferredStatusValue(matching keywords: [String]) -> String? {
        guard statusType == "status" || statusType == "select" else { return nil }
        return statusOptions.first { option in
            let lowered = option.lowercased()
            return keywords.contains { lowered.contains($0) }
        }
    }

    /// A read-only field rendered at the same metrics as the editable dropdowns,
    /// so a locked value (the title column) aligns with them instead of floating.
    func lockedFieldLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.muted).lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).frame(width: 196, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.cardElevated))
    }

    func mapRow<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }

    // MARK: Icons

    var placeholderSourceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
            Image(systemName: "folder").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.muted)
        }.frame(width: 26, height: 26)
    }

    var placeholderDestIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
            Image(systemName: "square.dashed").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.muted)
        }.frame(width: 26, height: 26)
    }

    var remindersGlyph: some View {
        Image("Reminders").resizable().interpolation(.high).scaledToFit().frame(width: 26, height: 26)
    }

    func sourceLabel(_ s: EditorSource) -> String {
        switch s { case .kind(let k): return k.label; case .reminders: return "Reminders" }
    }
    func sourceMenuIcon(_ s: EditorSource) -> AnyView {
        switch s {
        case .kind(let k): return AnyView(SourceIcon(kind: k, size: 26))
        case .reminders:   return AnyView(remindersGlyph)
        }
    }

    // MARK: Customize (inline destination form)

    var customizeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("CUSTOMIZE")
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
    var showCustomize: Bool {
        guard let toKind else { return false }
        if toKind == .notion {
            return localNotion.destinationType == .database && !localNotion.destinationId.isEmpty
        }
        return true
    }

    @ViewBuilder
    var destinationForm: some View {
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

    var chromeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sourceKind == .safari {
                HStack(alignment: .center, spacing: 14) {
                    Text("Exactly match Safari")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                    Spacer(minLength: 12)
                    Toggle("", isOn: $chromeMirrorExactly)
                        .labelsHidden().toggleStyle(.switch).tint(theme.primary)
                }
                Text("Chrome must be quit for changes to apply.")
                    .font(.system(size: 11)).foregroundStyle(theme.tertiary)
            } else {
                Text("Chrome folder")
                    .font(.system(size: 12)).foregroundStyle(theme.muted)
                TextField("From Safari", text: $chromeTargetFolder)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Mapping-only Notion form: the page/database is chosen in the To step, so
    /// Customize just maps note fields onto the database's columns.
    var notionMappingForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            if notionDestSchemaLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading database schema…").font(.system(size: 11)).foregroundStyle(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = notionDestSchemaError {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if notionDestSchema.isEmpty {
                Text("Choose a database in the To step to map its columns.")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    FieldMappingControl(rows: $localNotion.mappingRows,
                                        columns: notionMappingColumns,
                                        fieldOptions: mappingFieldOptions)
                }
            }
        }
    }

    /// The "from" fields offered in the column mapping, by source.
    var mappingFieldOptions: [MappingFieldOption] {
        sourceKind == .x ? MappingFieldOption.twitter : MappingFieldOption.remarkable
    }


    /// Mappable columns (the title column is set from the title strategy, so it's
    /// excluded); select / multi_select / status columns carry their options.
    var notionMappingColumns: [MappingColumn] {
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

    /// "Template" has no editor here, so it only shows for a sync already using it.
    var titleOptions: [(TitleStrategy, String)] {
        var options: [(TitleStrategy, String)] = [(.fileName, "File name"), (.firstLineOfOcr, "First line")]
        if titleStrategy == .template { options.append((.template, "Template")) }
        return options
    }

    var howStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("HOW")
            VStack(spacing: 0) {
                optionRow("Title each note") {
                    Segmented(selection: $titleStrategy, options: titleOptions)
                }
                rowDivider
                optionRow("Transcribe") {
                    Segmented(selection: $ocrMode, options: [(.all, "All pages"), (.handwrittenOnly, "Handwritten"), (.none, "None")])
                }
                rowDivider
                optionRow("Page order") {
                    Picker("", selection: $pageOrder) {
                        Text("Chronological").tag(PageOrder.chronological)
                        Text("Reverse chronological").tag(PageOrder.reverseChronological)
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                rowDivider
                optionRow("Only notes tagged", align: .top) { RequiredTagsControl(requiredTags: $requiredTags) }
                rowDivider
                optionRow("Attach original PDF") {
                    Toggle("", isOn: $savePdf).labelsHidden().toggleStyle(.switch).tint(theme.primary)
                }
            }
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
    }

    // MARK: Bits

    func stepLabel(_ tag: String) -> some View {
        Text(tag).font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(theme.primary)
    }

    var rowDivider: some View { Rectangle().fill(theme.dividerSubtle).frame(height: 1) }

    func optionRow<Trailing: View>(_ title: String, align: VerticalAlignment = .center, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: align, spacing: 14) {
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
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

    func load() {
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

    func loadOneWay(_ flow: SyncFlow) {
        existingBinding = flow.binding
        isEnabled = flow.binding.enabled
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

    func loadTask(_ sync: TaskSync) {
        source = .reminders
        originalTaskSyncId = sync.id
        isEnabled = sync.enabled
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

    func selectSource(forId id: String) {
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

    func loadSafariScopes() {
        pickers.run(.safariFolders) { safariScopes = try await coordinator.scopes(for: .safari) }
    }

    // MARK: X source

    /// Picks the first connected X account and a valid stream for it. Streams are
    /// static (no network), so the picker needs no loader.
    func applyXDefaults() {
        if xSourceAccountId == nil { xSourceAccountId = ledger.xAccounts.first?.id }
        if !xSourceStreams.contains(xSourceStream) {
            xSourceStream = xSourceStreams.first ?? .bookmarks
        }
    }

    func selectXAccount(_ id: String) {
        guard id != xSourceAccountId else { return }
        xSourceAccountId = id
        // Keep the chosen stream valid for the newly-selected account.
        if !xSourceStreams.contains(xSourceStream) {
            xSourceStream = xSourceStreams.first ?? .bookmarks
        }
    }

    // MARK: Notion source loaders

    func selectNotionSourceWorkspace(_ id: String) {
        guard id != notionSourceWorkspaceId else { return }
        notionSourceWorkspaceId = id
        notionSourceDatabaseId = nil; notionSourceDatabaseName = ""; notionSourceSchema = []
        loadNotionSourceDatabases()
    }

    func selectNotionSourceDatabase(_ id: String) {
        notionSourceDatabaseId = id
        notionSourceDatabaseName = notionSourceDatabases.first { $0.id == id }?.title ?? ""
        loadNotionSourceSchema()
    }

    func loadNotionSourceDatabases() {
        guard let workspaceId = notionSourceWorkspaceId else { return }
        pickers.run(.notionSourceDatabases) {
            let client = NotionClientFactory.make(workspaceId: workspaceId)
            let all = try await client.listDestinations(workspaceId: workspaceId)
            notionSourceDatabases = all.filter { $0.type == .database }
        }
    }

    func loadNotionSourceSchema() {
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

    func loadReminderLists() {
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
    func grantRemindersAccess() { loadReminderLists() }

    func selectTaskWorkspace(_ id: String) {
        guard id != taskWorkspaceId else { return }
        taskWorkspaceId = id
        taskDatabaseId = nil; taskDatabaseName = ""; taskSchema = []
        loadTaskDatabases()
    }

    func loadTaskDatabases() {
        guard let taskWorkspaceId else { return }
        pickers.run(.notionTaskDatabases) {
            let client = NotionClientFactory.make(workspaceId: taskWorkspaceId)
            let all = try await client.listDestinations(workspaceId: taskWorkspaceId)
            taskDatabases = all.filter { $0.type == .database }
        }
    }

    func selectTaskDatabase(_ id: String) {
        taskDatabaseId = id
        taskDatabaseName = taskDatabases.first { $0.id == id }?.title ?? ""
        mapRows = []; excludedStatuses = []
        loadTaskSchema()
    }

    func loadTaskSchema() {
        guard let taskWorkspaceId, let taskDatabaseId else { return }
        Task {
            let client = NotionClientFactory.make(workspaceId: taskWorkspaceId)
            let props = (try? await client.databaseSchema(destinationId: taskDatabaseId, workspaceId: taskWorkspaceId)) ?? []
            await MainActor.run { taskSchema = props }
        }
    }

    func loadNotionDestinations() {
        guard let id = toAccountId else { return }
        pickers.run(.notionDestinations) {
            let client = NotionClientFactory.make(workspaceId: id)
            notionDestinations = try await client.listDestinations(workspaceId: id)
        }
    }

    func selectNotionDestination(_ id: String) {
        guard let dest = notionDestinations.first(where: { $0.id == id }) else { return }
        localNotion.destinationId = dest.id
        localNotion.destinationType = dest.type
        localNotion.destinationTitle = dest.title
        localNotion.mappingRows = []
        notionDestSchema = []
        notionDestSchemaError = nil
        notionDestSchemaLoading = dest.type == .database
        if dest.type == .database { loadNotionDestSchema() }
    }

    func loadNotionDestSchema() {
        guard let id = toAccountId, !localNotion.destinationId.isEmpty else { return }
        let destinationId = localNotion.destinationId
        notionDestSchemaLoading = true
        notionDestSchemaError = nil
        notionDestSchema = []
        Task {
            do {
                let props = try await NotionClientFactory.make(workspaceId: id)
                    .databaseSchema(destinationId: destinationId, workspaceId: id)
                await MainActor.run {
                    notionDestSchema = props
                    notionDestSchemaLoading = false
                    notionDestSchemaError = props.isEmpty
                        ? "Sync Bar can read this database but it has no mappable columns."
                        : nil
                    seedTwitterMappingDefaults()
                }
            } catch {
                await MainActor.run {
                    notionDestSchema = []
                    notionDestSchemaLoading = false
                    notionDestSchemaError = "Couldn't read this database's columns: \(Formatters.userMessage(for: error)) Make sure it's shared with Sync Bar's Notion connection."
                }
            }
        }
    }

    /// Pre-fills the column mapping with sensible Twitter → Notion defaults the
    /// first time a database's schema arrives for a Twitter source. Only columns
    /// whose names/types we recognize are filled; everything stays editable.
    func seedTwitterMappingDefaults() {
        guard sourceKind == .x, localNotion.mappingRows.isEmpty, !notionDestSchema.isEmpty else { return }
        let streamTag = "Twitter \(xSourceStream.singularNoun)"
        var rows: [FieldMapping] = []
        for property in notionDestSchema where property.type != "title" {
            let name = property.name.lowercased()
            let isOption = ["select", "multi_select", "status"].contains(property.type)
            func option(_ wanted: String) -> NoteFieldValue? {
                property.options.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }.map { .options([$0]) }
            }
            var value: NoteFieldValue?
            if property.type == "url" || name == "url" {
                value = .custom("{tweet_url}")
            } else if name.contains("author") {
                value = .custom("{author}")
            } else if name == "site" {
                value = .custom("twitter.com")
            } else if name == "source" && isOption {
                value = option("Twitter")
            } else if name == "tags" || name == "tag" {
                value = isOption ? .options([streamTag]) : .custom(streamTag)
            } else if property.type == "date" {
                value = .custom("{date}")
            } else if name == "status" && isOption {
                value = option("Inbox")
            }
            if let value { rows.append(FieldMapping(key: property.name, value: value)) }
        }
        localNotion.mappingRows = rows
    }

    func loadFormState(from configuration: DestinationConfiguration) {
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

    func selectFolder(_ f: RmFolder) { folder = f; selectedFileIds = nil }

    func selectDestination(_ app: ConnectedApp) {
        toKind = app.kind
        toAccountId = app.id
        switch app.kind {
        case .notion:
            localNotion = NotionFormState(workspaceId: app.id)
            notionDestinations = []; notionDestSchema = []
            notionDestSchemaError = nil; notionDestSchemaLoading = false
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

    var destinationValid: Bool {
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

    func composedConfiguration() -> DestinationConfiguration? {
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

    func openScope() {
        guard let folder else { return }
        isChoosingScope = true
        scopeLoading = true
        Task {
            let files = await coordinator.files(inFolder: folder.id)
            await MainActor.run { scopeFiles = files; scopeLoading = false }
        }
    }
}
