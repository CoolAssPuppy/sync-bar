//
//  RuleSheetView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

/// Right-edge slider shown when a notebook is selected. Lets the user
/// attach zero or more destinations to that notebook and tweak the
/// rule-level sync defaults.
struct RuleSliderView: View {
    let notebook: RmFolder
    let coordinator: SyncCoordinator
    var onClose: () -> Void
    var onSyncNow: (String, String?) -> Void   // (ruleId, optional bindingId)

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var existingBindingIdToEdit: String?
    /// The folder's documents, loaded for the "choose notebooks" picker.
    @State private var folderFiles: [RmFile] = []
    @State private var isLoadingFiles = false

    /// Either an existing rule for this notebook, or nil. When nil we
    /// create a fresh rule the first time the user attaches a destination.
    private var rule: SyncRule? {
        ledger.rule(forNotebookId: notebook.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ruleSettingsCard
                    notebooksCard
                    destinationsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            Divider().background(theme.divider)
            footer
        }
        .background(theme.surface)
        .overlay(
            Rectangle().fill(theme.divider).frame(width: 1),
            alignment: .leading
        )
        .sheet(isPresented: Binding(
            get: { existingBindingIdToEdit != nil },
            set: { if !$0 { existingBindingIdToEdit = nil } }
        )) {
            if let id = existingBindingIdToEdit,
               let rule, let binding = rule.destinations.first(where: { $0.id == id }) {
                BindingEditorSheet(
                    kind: binding.kind,
                    notebook: notebook,
                    existingBinding: binding,
                    onSave: { updated in
                        ledger.updateBinding(ruleId: rule.id, binding: updated)
                        existingBindingIdToEdit = nil
                    },
                    onCancel: { existingBindingIdToEdit = nil }
                )
            }
        }
        .task(id: notebook.id) {
            isLoadingFiles = true
            folderFiles = await coordinator.files(inFolder: notebook.id)
            isLoadingFiles = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule == nil ? "Set Up Sync for This Folder" : "Edit Sync Rule")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            if let rule {
                let status = ruleStatus(rule)
                Image(systemName: status.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.color)
                    .help(status.help)
                Toggle("", isOn: ruleEnabledBinding(rule))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(theme.primary)
                    .help(rule.enabled ? "Disable rule" : "Enable rule")
                AppIconButton(systemName: "trash", help: "Delete rule", tint: .destructive) {
                    ledger.deleteRule(id: rule.id)
                    onClose()
                }
            }
            AppIconButton(systemName: "xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Header line: the folder name plus how many of its notebooks the rule syncs.
    private var headerSubtitle: String {
        let total = notebook.pageCount
        let totalLabel = "\(total) notebook\(total == 1 ? "" : "s")"
        if let rule, !rule.syncsEntireFolder {
            let selected = rule.selectedFileIds?.count ?? 0
            return "\(notebook.name) · syncing \(selected) of \(totalLabel)"
        }
        return "\(notebook.name) · \(totalLabel)"
    }

    private struct RuleStatusGlyph {
        let symbol: String
        let color: Color
        let help: String
    }

    /// Health glyph for the rule: green check when syncing cleanly, yellow
    /// triangle on partial failures, red triangle on errors, muted otherwise.
    private func ruleStatus(_ rule: SyncRule) -> RuleStatusGlyph {
        guard rule.enabled else { return RuleStatusGlyph(symbol: "pause.circle.fill", color: theme.tertiary, help: "Disabled") }
        let statuses = rule.destinations.map(\.lastRunStatus)
        if statuses.contains(.error)   { return RuleStatusGlyph(symbol: "exclamationmark.triangle.fill", color: theme.destructive, help: "Last sync failed") }
        if statuses.contains(.partial) { return RuleStatusGlyph(symbol: "exclamationmark.triangle.fill", color: theme.warning, help: "Some pages failed") }
        if statuses.contains(.success) { return RuleStatusGlyph(symbol: "checkmark.circle.fill", color: theme.success, help: "Syncing normally") }
        return RuleStatusGlyph(symbol: "circle", color: theme.tertiary, help: "Not yet run")
    }

    // MARK: Rule-level settings card

    private var ruleSettingsCard: some View {
        AppCard("Defaults for This Folder") {
            VStack(spacing: 0) {
                AppSettingRow("Title strategy", description: "How each page is titled at every destination.") {
                    Picker("", selection: titleStrategyBinding) {
                        ForEach(TitleStrategy.allCases) { strategy in
                            Text(strategy.label).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if currentTitleStrategy == .template {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Template", description: "Tokens: {folder_name}, {notebook}, {date}, {today}") {
                        TextField("Template", text: titleTemplateBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("OCR mode", description: "What to transcribe.") {
                    Picker("", selection: ocrModeBinding) {
                        ForEach(OcrMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                // No "Attach PDF" toggle yet: the sync path never produces a PDF
                // (pdfData is always nil), and Notion's API can't accept a local
                // file upload (it references files by URL only), so a hosted-URL
                // path must exist before attachment can be offered per destination.
            }
        }
    }

    // MARK: Notebooks card

    /// Sync the whole folder, or hand-pick notebooks (e.g. "only my journal").
    /// "Sync every notebook" maps to a nil scope; checking notebooks sets the
    /// rule's `selectedFileIds`.
    private var notebooksCard: some View {
        AppCard("Notebooks") {
            VStack(spacing: 0) {
                AppSettingRow("Sync every notebook", description: syncsEntireFolder
                              ? "Every notebook in this folder syncs, including new ones."
                              : "Only the notebooks you check below sync.") {
                    Toggle("", isOn: syncAllBinding)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
                if !syncsEntireFolder {
                    AppRowDivider().padding(.vertical, 10)
                    notebookChecklist
                }
            }
        }
    }

    @ViewBuilder
    private var notebookChecklist: some View {
        if isLoadingFiles {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading notebooks…").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if folderFiles.isEmpty {
            Text("No notebooks in this folder.")
                .font(.system(size: 11)).foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 4) {
                ForEach(folderFiles) { file in
                    Button(action: { toggleFile(file, on: !isSelected(file)) }) {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected(file) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(isSelected(file) ? theme.primary : theme.tertiary)
                            Text(file.name).font(.system(size: 12)).foregroundStyle(theme.foreground).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(file.pageCount) page\(file.pageCount == 1 ? "" : "s")")
                                .font(.system(size: 10)).foregroundStyle(theme.muted)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var syncsEntireFolder: Bool { rule?.syncsEntireFolder ?? true }

    private var syncAllBinding: Binding<Bool> {
        Binding(
            get: { syncsEntireFolder },
            set: { all in
                var copy = ensureRule()
                copy.selectedFileIds = all ? nil : folderFiles.map(\.id)
                ledger.upsertRule(copy)
            }
        )
    }

    private func isSelected(_ file: RmFile) -> Bool {
        rule?.includes(fileId: file.id) ?? true
    }

    private func toggleFile(_ file: RmFile, on: Bool) {
        var copy = ensureRule()
        var ids = Set(copy.selectedFileIds ?? folderFiles.map(\.id))
        if on { ids.insert(file.id) } else { ids.remove(file.id) }
        // Persist in folder order so the stored list is stable and readable.
        copy.selectedFileIds = folderFiles.map(\.id).filter { ids.contains($0) }
        ledger.upsertRule(copy)
    }

    // MARK: Destinations card

    private var destinationsCard: some View {
        AppCard("Destinations", trailing: { addDestinationMenu }) {
            if let rule, !rule.destinations.isEmpty {
                populatedDestinations(rule: rule)
            } else {
                emptyDestinations
            }
        }
    }

    /// "+" in the card header: a menu of the destinations the user has already
    /// connected. Picking one attaches it to this notebook's rule immediately.
    private var addDestinationMenu: some View {
        Menu {
            let items = configuredDestinations()
            if items.isEmpty {
                Text("No destinations connected. Add one from the sidebar first.")
            } else {
                ForEach(items) { item in
                    Button(action: { addConfigured(item) }) {
                        Label(item.label, systemImage: item.kind.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.primaryForeground)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [theme.primary, theme.primaryDeep], startPoint: .top, endPoint: .bottom))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a connected destination")
    }

    @ViewBuilder
    private var emptyDestinations: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.tertiary)
            Text("No destinations yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
            Text("Use the + above to attach a place you've already connected.")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: Configured destinations

    private struct ConfiguredDestination: Identifiable {
        let id: String
        let kind: DestinationKind
        let label: String
        let makeConfiguration: () -> DestinationConfiguration
    }

    private func configuredDestinations() -> [ConfiguredDestination] {
        var items: [ConfiguredDestination] = []
        for workspace in ledger.notionWorkspaces {
            items.append(ConfiguredDestination(id: "notion-\(workspace.id)", kind: .notion, label: "Notion · \(workspace.workspaceName)") {
                .notion(NotionDestinationConfig(workspaceId: workspace.id, destinationId: "",
                    destinationType: .page, destinationTitle: workspace.workspaceName, propertyMappings: [:]))
            })
        }
        for account in ledger.linearAccounts {
            items.append(ConfiguredDestination(id: "linear-\(account.id)", kind: .linear, label: "Linear · \(account.name)") {
                .linear(LinearDestinationConfig(workspaceId: account.id, workspaceName: account.name,
                    projectId: nil, projectName: nil, defaultLabel: nil))
            })
        }
        for account in ledger.googleAccounts {
            items.append(ConfiguredDestination(id: "google-\(account.id)", kind: .googleDocs, label: "Google Docs · \(account.displayName)") {
                .googleDocs(GoogleDocsDestinationConfig(accountEmail: account.id, folderId: nil, folderName: nil, appendMode: .onePerPage))
            })
        }
        for target in ledger.appleNotesTargets {
            items.append(ConfiguredDestination(id: "an-\(target.id)", kind: .appleNotes, label: "Apple Notes") {
                .appleNotes(AppleNotesDestinationConfig(folderName: target.folderName))
            })
        }
        for target in ledger.markdownTargets {
            // Inherit the destination's default config (folder + template +
            // frontmatter), chosen when the destination was created.
            items.append(ConfiguredDestination(id: "md-\(target.id)", kind: .markdownFolder, label: "Markdown · \(target.displayName)") {
                .markdownFolder(target.defaultConfiguration)
            })
        }
        return items
    }

    private func addConfigured(_ item: ConfiguredDestination) {
        let ruleId = ensureRule().id
        let binding = DestinationBinding(configuration: item.makeConfiguration())
        ledger.addBinding(ruleId: ruleId, binding: binding)
    }

    @ViewBuilder
    private func populatedDestinations(rule: SyncRule) -> some View {
        VStack(spacing: 8) {
            ForEach(rule.destinations) { binding in
                RuleDestinationRow(
                    binding: binding,
                    onEdit: { existingBindingIdToEdit = binding.id },
                    onSync: { onSyncNow(rule.id, binding.id) },
                    onToggle: { newValue in
                        var copy = binding
                        copy.enabled = newValue
                        ledger.updateBinding(ruleId: rule.id, binding: copy)
                    },
                    onRemove: { ledger.removeBinding(ruleId: rule.id, bindingId: binding.id) }
                )
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if let rule, !rule.destinations.isEmpty {
                AppPrimaryButton(title: "Sync all destinations now", systemImage: "arrow.triangle.2.circlepath") {
                    onSyncNow(rule.id, nil)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.background)
    }

    // MARK: Bindings & helpers

    private func ensureRule() -> SyncRule {
        if let rule { return rule }
        let new = SyncRule.new(notebookId: notebook.id, notebookName: notebook.name)
        ledger.upsertRule(new)
        return new
    }

    private var currentTitleStrategy: TitleStrategy { rule?.titleStrategy ?? .firstLineOfOcr }

    private func ruleEnabledBinding(_ rule: SyncRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in
                var copy = rule
                copy.enabled = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var titleStrategyBinding: Binding<TitleStrategy> {
        Binding(
            get: { rule?.titleStrategy ?? .firstLineOfOcr },
            set: { newValue in
                var copy = ensureRule()
                copy.titleStrategy = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var titleTemplateBinding: Binding<String> {
        Binding(
            get: { rule?.titleTemplate ?? defaultTitleTemplate },
            set: { newValue in
                var copy = ensureRule()
                copy.titleTemplate = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var ocrModeBinding: Binding<OcrMode> {
        Binding(
            get: { rule?.ocrMode ?? .all },
            set: { newValue in
                var copy = ensureRule()
                copy.ocrMode = newValue
                ledger.upsertRule(copy)
            }
        )
    }
}

// MARK: - Destination row

/// One destination in a rule: icon + name / type / last-sync status on the
/// left, an enable toggle and minimized edit / sync / remove icons on the right.
private struct RuleDestinationRow: View {
    let binding: DestinationBinding
    let onEdit: () -> Void
    let onSync: () -> Void
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            DestinationIcon(kind: binding.kind, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(binding.configuration.summary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    if hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.destructive)
                            .help(binding.lastRunError ?? "Last sync failed")
                    }
                }
                Text(binding.kind.label)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
                Text(statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            AppIconButton(systemName: "pencil", help: "Edit", action: onEdit)
            AppIconButton(systemName: "arrow.triangle.2.circlepath", help: "Sync now", spinOnTap: true, action: onSync)
            AppIconButton(systemName: "trash", help: "Remove", tint: .destructive, action: onRemove)

            Toggle("", isOn: Binding(get: { binding.enabled }, set: { onToggle($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                .padding(.leading, 4)
                .help(binding.enabled ? "Disable this destination" : "Enable this destination")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .opacity(binding.enabled ? 1 : 0.6)
    }

    private var statusLine: String {
        if !binding.enabled { return "Off" }
        if let error = binding.lastRunError, !error.isEmpty { return error }
        if let lastRun = binding.lastRunAt {
            return "\(Formatters.syncResultLabel(pageCount: binding.lastRunPagesSynced)) · \(Formatters.relativeLabel(for: lastRun))"
        }
        return "Never synced"
    }

    private var statusColor: Color {
        if !binding.enabled { return theme.tertiary }
        switch binding.lastRunStatus {
        case .error:   return theme.destructive
        case .partial: return theme.warning
        case .success: return theme.success
        default:       return theme.muted
        }
    }

    private var hasError: Bool {
        if case .error = binding.lastRunStatus { return true }
        return !(binding.lastRunError ?? "").isEmpty
    }
}
