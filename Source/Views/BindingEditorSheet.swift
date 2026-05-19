//
//  BindingEditorSheet.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

/// Sheet for creating or editing one DestinationBinding. Routes between
/// destination-specific config UIs based on `kind`.
struct BindingEditorSheet: View {
    let kind: DestinationKind
    let notebook: RmNotebook
    let existingBinding: DestinationBinding?
    var onSave: (DestinationBinding) -> Void
    var onCancel: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            header(theme: theme)
            Divider().background(theme.divider)
            ScrollView {
                form
                    .padding(20)
            }
            Divider().background(theme.divider)
            footer(theme: theme)
        }
        .frame(width: 560, height: 520)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: Form router

    @ViewBuilder
    private var form: some View {
        switch kind {
        case .notion:         NotionForm(binding: $localNotion, workspaces: ledger.notionWorkspaces)
        case .linear:         LinearForm(binding: $localLinear, accounts: ledger.linearAccounts)
        case .googleDocs:     GoogleDocsForm(binding: $localGoogle, accounts: ledger.googleAccounts)
        case .appleNotes:     AppleNotesForm(binding: $localAppleNotes, targets: ledger.appleNotesTargets)
        case .markdownFolder: MarkdownForm(binding: $localMarkdown, targets: ledger.markdownTargets)
        }
    }

    // MARK: Header / Footer

    private func header(theme: ThemePalette) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(existingBinding == nil ? "Add \(kind.label) destination" : "Edit \(kind.label) destination")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("For \(notebook.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.card))
                    .overlay(Circle().strokeBorder(theme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func footer(theme: ThemePalette) -> some View {
        HStack {
            Spacer()
            AppSecondaryButton(title: "Cancel", action: onCancel)
            AppPrimaryButton(title: existingBinding == nil ? "Add" : "Save", systemImage: "checkmark", isDisabled: !canSave) {
                save()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.surface)
    }

    // MARK: Local form state per kind

    @State private var localNotion = NotionFormState()
    @State private var localLinear = LinearFormState()
    @State private var localGoogle = GoogleFormState()
    @State private var localAppleNotes = AppleNotesFormState()
    @State private var localMarkdown = MarkdownFormState()

    init(kind: DestinationKind, notebook: RmNotebook, existingBinding: DestinationBinding?, onSave: @escaping (DestinationBinding) -> Void, onCancel: @escaping () -> Void) {
        self.kind = kind
        self.notebook = notebook
        self.existingBinding = existingBinding
        self.onSave = onSave
        self.onCancel = onCancel
        if let existingBinding {
            switch existingBinding.configuration {
            case .notion(let cfg):
                _localNotion = State(initialValue: NotionFormState(
                    workspaceId: cfg.workspaceId,
                    destinationId: cfg.destinationId,
                    destinationType: cfg.destinationType,
                    destinationTitle: cfg.destinationTitle,
                    propertyMappings: cfg.propertyMappings
                ))
            case .linear(let cfg):
                _localLinear = State(initialValue: LinearFormState(workspaceId: cfg.workspaceId, projectId: cfg.projectId ?? "", projectName: cfg.projectName ?? "", defaultLabel: cfg.defaultLabel ?? ""))
            case .googleDocs(let cfg):
                _localGoogle = State(initialValue: GoogleFormState(email: cfg.accountEmail, folderId: cfg.folderId ?? "", folderName: cfg.folderName ?? "", appendMode: cfg.appendMode))
            case .appleNotes(let cfg):
                _localAppleNotes = State(initialValue: AppleNotesFormState(folderName: cfg.folderName))
            case .markdownFolder(let cfg):
                _localMarkdown = State(initialValue: MarkdownFormState(folderPath: cfg.folderPath, fileNameTemplate: cfg.fileNameTemplate, includeFrontmatter: cfg.includeFrontmatter))
            }
        }
    }

    // MARK: Save

    private var canSave: Bool {
        switch kind {
        case .notion:         return !localNotion.workspaceId.isEmpty && !localNotion.destinationId.isEmpty
        case .linear:         return !localLinear.workspaceId.isEmpty
        case .googleDocs:     return !localGoogle.email.isEmpty
        case .appleNotes:     return !localAppleNotes.folderName.isEmpty
        case .markdownFolder: return !localMarkdown.folderPath.isEmpty
        }
    }

    private func save() {
        let configuration: DestinationConfiguration
        switch kind {
        case .notion:
            configuration = .notion(NotionDestinationConfig(
                workspaceId: localNotion.workspaceId,
                destinationId: localNotion.destinationId,
                destinationType: localNotion.destinationType,
                destinationTitle: localNotion.destinationTitle,
                propertyMappings: localNotion.destinationType == .database ? localNotion.propertyMappings : [:]
            ))
        case .linear:
            let project = localLinear.projectId.isEmpty ? nil : localLinear.projectId
            let projectName = localLinear.projectName.isEmpty ? nil : localLinear.projectName
            let team = ledger.linearAccounts.first(where: { $0.id == localLinear.workspaceId })
            configuration = .linear(LinearDestinationConfig(
                workspaceId: localLinear.workspaceId,
                workspaceName: team?.name ?? "",
                projectId: project,
                projectName: projectName,
                defaultLabel: localLinear.defaultLabel.isEmpty ? nil : localLinear.defaultLabel
            ))
        case .googleDocs:
            configuration = .googleDocs(GoogleDocsDestinationConfig(
                accountEmail: localGoogle.email,
                folderId: localGoogle.folderId.isEmpty ? nil : localGoogle.folderId,
                folderName: localGoogle.folderName.isEmpty ? nil : localGoogle.folderName,
                appendMode: localGoogle.appendMode
            ))
        case .appleNotes:
            configuration = .appleNotes(AppleNotesDestinationConfig(folderName: localAppleNotes.folderName))
        case .markdownFolder:
            configuration = .markdownFolder(MarkdownFolderDestinationConfig(
                folderPath: localMarkdown.folderPath,
                fileNameTemplate: localMarkdown.fileNameTemplate.isEmpty ? "{notebook}-page-{page_n}" : localMarkdown.fileNameTemplate,
                includeFrontmatter: localMarkdown.includeFrontmatter
            ))
        }
        let binding = DestinationBinding(
            id: existingBinding?.id ?? UUID().uuidString,
            enabled: existingBinding?.enabled ?? true,
            configuration: configuration,
            createdAt: existingBinding?.createdAt ?? Date(),
            lastRunAt: existingBinding?.lastRunAt,
            lastRunStatus: existingBinding?.lastRunStatus ?? .neverRun,
            lastRunPagesSynced: existingBinding?.lastRunPagesSynced ?? 0,
            lastRunError: existingBinding?.lastRunError,
            ocrModeOverride: existingBinding?.ocrModeOverride,
            titleStrategyOverride: existingBinding?.titleStrategyOverride
        )
        onSave(binding)
    }
}

// MARK: - Form state

private struct NotionFormState {
    var workspaceId: String = ""
    var destinationId: String = ""
    var destinationType: NotionDestinationType = .page
    var destinationTitle: String = ""
    var propertyMappings: [String: NotionPropertyMapping] = [:]
}
private struct LinearFormState {
    var workspaceId: String = ""
    var projectId: String = ""
    var projectName: String = ""
    var defaultLabel: String = ""
}
private struct GoogleFormState {
    var email: String = ""
    var folderId: String = ""
    var folderName: String = ""
    var appendMode: GoogleDocsDestinationConfig.AppendMode = .onePerPage
}
private struct AppleNotesFormState {
    var folderName: String = "SyncNerds"
}
private struct MarkdownFormState {
    var folderPath: String = ""
    var fileNameTemplate: String = "{notebook}-page-{page_n}"
    var includeFrontmatter: Bool = true
}

// MARK: - Per-kind forms

private struct NotionForm: View {
    @Binding var binding: NotionFormState
    let workspaces: [NotionWorkspace]
    @State private var destinations: [NotionDestination] = []
    @State private var schema: [NotionDatabaseProperty] = []
    @Environment(\.theme) private var theme
    private let notion = MockNotionClient()

    var body: some View {
        VStack(spacing: 14) {
            AppCard("Notion") {
                VStack(spacing: 0) {
                    AppSettingRow("Workspace", description: nil) {
                        Picker("", selection: $binding.workspaceId) {
                            Text("Select…").tag("")
                            ForEach(workspaces) { workspace in
                                Text(workspace.workspaceName).tag(workspace.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        .onChange(of: binding.workspaceId) { _, newValue in
                            Task { await loadDestinations(workspaceId: newValue) }
                        }
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Page or database", description: nil) {
                        Picker("", selection: $binding.destinationId) {
                            Text("Select…").tag("")
                            ForEach(destinations) { destination in
                                Text("\(destination.icon ?? "•") \(destination.title)").tag(destination.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        .onChange(of: binding.destinationId) { _, newValue in
                            if let dest = destinations.first(where: { $0.id == newValue }) {
                                binding.destinationType = dest.type
                                binding.destinationTitle = dest.title
                                if dest.type == .database {
                                    Task { await loadSchema(destinationId: newValue) }
                                } else {
                                    schema = []
                                }
                            }
                        }
                    }
                }
            }
            if binding.destinationType == .database, !schema.isEmpty {
                AppCard("Column mapping") {
                    VStack(spacing: 0) {
                        ForEach(Array(schema.enumerated()), id: \.offset) { index, property in
                            if index > 0 { AppRowDivider().padding(.vertical, 10) }
                            NotionColumnMappingRow(property: property,
                                                   mapping: bindingForProperty(property))
                        }
                    }
                }
            }
        }
        .task {
            await loadDestinations(workspaceId: binding.workspaceId)
            if binding.destinationType == .database {
                await loadSchema(destinationId: binding.destinationId)
            }
        }
    }

    private func bindingForProperty(_ property: NotionDatabaseProperty) -> Binding<NotionPropertyMapping> {
        Binding(
            get: { binding.propertyMappings[property.name] ?? .leaveBlank },
            set: { binding.propertyMappings[property.name] = $0 }
        )
    }

    private func loadDestinations(workspaceId: String) async {
        guard !workspaceId.isEmpty else { destinations = []; return }
        let result = (try? await notion.listDestinations(workspaceId: workspaceId)) ?? []
        await MainActor.run { destinations = result }
    }

    private func loadSchema(destinationId: String) async {
        guard !destinationId.isEmpty else { schema = []; return }
        let result = (try? await notion.databaseSchema(destinationId: destinationId, workspaceId: binding.workspaceId)) ?? []
        await MainActor.run { schema = result }
    }
}

/// Renders the right kind of editor for each Notion property type, including
/// a multi-select chip box for `multi_select` columns.
private struct NotionColumnMappingRow: View {
    let property: NotionDatabaseProperty
    @Binding var mapping: NotionPropertyMapping
    @Environment(\.theme) private var theme

    var body: some View {
        AppSettingRow(LocalizedStringKey(property.name), description: LocalizedStringKey(property.type)) {
            editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch property.type {
        case "title":
            Text("Auto from title strategy")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        case "select", "status":
            singleOptionPicker
        case "multi_select":
            MultiSelectChipBox(options: property.options,
                               selection: Binding(
                                get: { currentMultiSelectValues },
                                set: { mapping = .multiSelectOptions($0) }
                               ))
                .frame(maxWidth: 280, alignment: .trailing)
        case "date":
            datePicker
        case "checkbox":
            checkboxPicker
        case "number":
            numberField
        case "rich_text", "url", "email", "phone_number":
            textField
        default:
            Text("Leave blank")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        }
    }

    private var singleOptionPicker: some View {
        Picker("", selection: Binding<String>(
            get: { currentSelectValue },
            set: { newValue in mapping = newValue.isEmpty ? .leaveBlank : .selectOption(newValue) }
        )) {
            Text("Leave blank").tag("")
            ForEach(property.options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private var datePicker: some View {
        Picker("", selection: Binding<String>(
            get: {
                if case .dateSource(let source) = mapping { return source.rawValue }
                return ""
            },
            set: { raw in
                if raw.isEmpty { mapping = .leaveBlank }
                else if let source = NotionPropertyMapping.DateSource(rawValue: raw) {
                    mapping = .dateSource(source)
                }
            }
        )) {
            Text("Leave blank").tag("")
            ForEach(NotionPropertyMapping.DateSource.allCases) { source in
                Text(source.label).tag(source.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private var checkboxPicker: some View {
        Picker("", selection: Binding<Int>(
            get: {
                if case .checkbox(let value) = mapping { return value ? 1 : 0 }
                return -1
            },
            set: { tag in
                if tag == -1 { mapping = .leaveBlank }
                else { mapping = .checkbox(tag == 1) }
            }
        )) {
            Text("Leave blank").tag(-1)
            Text("Unchecked").tag(0)
            Text("Checked").tag(1)
        }
        .labelsHidden()
        .frame(width: 160)
    }

    private var numberField: some View {
        TextField("Number", text: Binding<String>(
            get: {
                if case .number(let value) = mapping { return String(value) }
                return ""
            },
            set: { raw in
                if raw.isEmpty { mapping = .leaveBlank }
                else if let value = Double(raw) { mapping = .number(value) }
            }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: 160)
    }

    private var textField: some View {
        TextField("Leave blank or use a template", text: Binding<String>(
            get: {
                switch mapping {
                case .text(let template): return template
                case .literal(let value): return value
                default: return ""
                }
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { mapping = .leaveBlank }
                else if property.type == "rich_text" { mapping = .text(template: trimmed) }
                else { mapping = .literal(trimmed) }
            }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 280)
    }

    private var currentSelectValue: String {
        if case .selectOption(let value) = mapping { return value }
        return ""
    }

    private var currentMultiSelectValues: [String] {
        if case .multiSelectOptions(let values) = mapping { return values }
        return []
    }
}

/// Chip-box editor for multi-select columns. + button pops a menu of the
/// remaining Notion options; each existing chip has a × to remove it.
private struct MultiSelectChipBox: View {
    let options: [String]
    @Binding var selection: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let remaining = options.filter { !selection.contains($0) }
        HStack(alignment: .center, spacing: 6) {
            ForEach(selection, id: \.self) { value in
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.primary)
                    Button(action: { selection.removeAll { $0 == value } }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.primary.opacity(0.12)))
                .overlay(Capsule().strokeBorder(theme.primary.opacity(0.3), lineWidth: 1))
            }
            if !remaining.isEmpty {
                Menu {
                    ForEach(remaining, id: \.self) { option in
                        Button(option) { selection.append(option) }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 18, height: 18)
                        .background(Capsule().fill(theme.primary.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(theme.primary.opacity(0.3), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(6)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}

private struct LinearForm: View {
    @Binding var binding: LinearFormState
    let accounts: [LinearAccount]

    var body: some View {
        AppCard("Linear") {
            VStack(spacing: 0) {
                AppSettingRow("Team", description: nil) {
                    Picker("", selection: $binding.workspaceId) {
                        Text("Select…").tag("")
                        ForEach(accounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Project (optional)", description: nil) {
                    TextField("Project ID or slug", text: $binding.projectId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Default label (optional)", description: nil) {
                    TextField("e.g. captured-from-rm", text: $binding.defaultLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
        }
    }
}

private struct GoogleDocsForm: View {
    @Binding var binding: GoogleFormState
    let accounts: [GoogleAccount]

    var body: some View {
        AppCard("Google Docs") {
            VStack(spacing: 0) {
                AppSettingRow("Account", description: nil) {
                    Picker("", selection: $binding.email) {
                        Text("Select…").tag("")
                        ForEach(accounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Drive folder (optional)", description: "Drive folder ID. Leave blank to drop docs at the user's root.") {
                    TextField("Drive folder ID", text: $binding.folderId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Append mode", description: nil) {
                    Picker("", selection: $binding.appendMode) {
                        ForEach(GoogleDocsDestinationConfig.AppendMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
        }
    }
}

private struct AppleNotesForm: View {
    @Binding var binding: AppleNotesFormState
    let targets: [AppleNotesTarget]

    var body: some View {
        AppCard("Apple Notes") {
            VStack(spacing: 0) {
                AppSettingRow("Folder", description: "SyncNerds creates the folder in iCloud Notes if it doesn't exist.") {
                    TextField("Folder name", text: $binding.folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                if !targets.isEmpty {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Existing folders", description: nil) {
                        Picker("", selection: $binding.folderName) {
                            ForEach(targets) { target in
                                Text(target.folderName).tag(target.folderName)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }
        }
    }
}

private struct MarkdownForm: View {
    @Binding var binding: MarkdownFormState
    let targets: [MarkdownTarget]

    var body: some View {
        AppCard("Markdown files") {
            VStack(spacing: 0) {
                AppSettingRow("Folder", description: "Where the .md files land.") {
                    HStack(spacing: 6) {
                        Text(binding.folderPath.isEmpty ? "Not chosen" : binding.folderPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                        AppSecondaryButton(title: "Choose…", systemImage: "folder") {
                            chooseFolder()
                        }
                    }
                }
                if !targets.isEmpty {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Pick an existing target", description: nil) {
                        Picker("", selection: $binding.folderPath) {
                            ForEach(targets) { target in
                                Text(target.displayName).tag(target.folderPath)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("File name template", description: "Tokens: {notebook}, {page_n}, {date}, {title}") {
                    TextField("{notebook}-page-{page_n}", text: $binding.fileNameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Include YAML frontmatter", description: nil) {
                    Toggle("", isOn: $binding.includeFrontmatter)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Pick a folder for Markdown notes"
        if panel.runModal() == .OK, let url = panel.url {
            binding.folderPath = url.path
        }
    }
}
