//
//  SyncEditorView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The one place a Sync is created or edited: From a Source folder, To a
//  Destination, Customize the destination, and How it runs. Maps the single
//  "Sync" object onto the underlying rule + binding.
//

import SwiftUI

enum SyncEditorTarget: Identifiable {
    case new
    case edit(SyncFlow)
    var id: String { if case .edit(let f) = self { return f.id }; return "new" }
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
        return out
    }
}

struct SyncEditorView: View {
    let target: SyncEditorTarget
    @ObservedObject var coordinator: SyncCoordinator
    var onClose: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    // From
    @State private var folder: RmFolder?
    @State private var selectedFileIds: [String]?
    // To
    @State private var toKind: DestinationKind?
    @State private var toAccountId: String?
    // Customize — per-kind destination forms
    @State private var localNotion = NotionFormState()
    @State private var localLinear = LinearFormState()
    @State private var localGoogle = GoogleFormState()
    @State private var localAppleNotes = AppleNotesFormState()
    @State private var localMarkdown = MarkdownFormState()
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

    private var isEditing: Bool { originalBindingId != nil }
    private var canSave: Bool { folder != nil && toKind != nil && destinationValid }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fromStep
                    toStep
                    if toKind != nil { customizeStep }
                    howStep
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
                Text("From a source, to a destination, synced how.").font(.system(size: 12.5)).foregroundStyle(theme.muted)
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

    // MARK: From

    private var fromStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("FROM", "which source folder")
            CustomDropdown(
                options: ledger.folders.map { DropdownOption(id: $0.id, icon: AnyView(SourceMark(size: 26)), title: $0.name) },
                selectedId: folder?.id,
                placeholder: "Choose a folder",
                placeholderIcon: AnyView(SourceMark(size: 26)),
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

    private var scopeSummary: String {
        guard let ids = selectedFileIds, !ids.isEmpty else { return "Syncing every notebook in this folder" }
        return "Syncing \(ids.count) selected notebook\(ids.count == 1 ? "" : "s")"
    }

    // MARK: To

    private var toStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("TO", "which destination")
            CustomDropdown(
                options: ledger.connectedApps.map { DropdownOption(id: $0.id, icon: AnyView(DestinationIcon(kind: $0.kind, size: 24)), title: $0.name) },
                selectedId: toAccountId,
                placeholder: ledger.hasAnyDestination ? "Choose a destination" : "Connect a destination first",
                placeholderIcon: AnyView(placeholderDestIcon),
                onSelect: { id in if let app = ledger.connectedApps.first(where: { $0.id == id }) { selectDestination(app) } }
            )
        }
    }

    private var placeholderDestIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
            Image(systemName: "square.dashed").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.muted)
        }.frame(width: 26, height: 26)
    }

    // MARK: Customize (inline destination form)

    private var customizeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("CUSTOMIZE", "configure this destination and map fields")
            VStack(spacing: 14) { destinationForm }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var destinationForm: some View {
        switch toKind {
        case .notion:         NotionForm(binding: $localNotion, workspaces: ledger.notionWorkspaces)
        case .linear:         LinearForm(binding: $localLinear, accounts: ledger.linearAccounts)
        case .googleDocs:     GoogleDocsForm(binding: $localGoogle)
        case .appleNotes:     AppleNotesForm(binding: $localAppleNotes)
        case .markdownFolder: MarkdownForm(binding: $localMarkdown, targets: ledger.markdownTargets)
        case .none:           EmptyView()
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
                Text("Choose notebooks").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.foreground)
                Spacer()
                PillButton(title: "Done", action: { isChoosingScope = false })
            }.padding(18)
            Rectangle().fill(theme.divider).frame(height: 1)
            NotebookScopePicker(files: scopeFiles, isLoading: scopeLoading, selectedFileIds: selectedFileIds) { selectedFileIds = $0 }
                .frame(minHeight: 320)
        }
        .frame(width: 520, height: 480)
        .background(theme.surface)
        .environment(\.theme, theme)
    }

    // MARK: Logic

    private func load() {
        guard case .edit(let flow) = target else { return }
        folder = ledger.folders.first(where: { $0.id == flow.folderId })
            ?? RmFolder(id: flow.folderId, name: flow.folderName, parentFolder: nil, lastModified: Date(), pageCount: 0)
        selectedFileIds = flow.rule.selectedFileIds
        pageOrder = flow.rule.pageOrder
        savePdf = flow.rule.savePdfAttachment
        titleStrategy = flow.titleStrategy
        ocrMode = flow.ocrMode
        requiredTags = flow.requiredTags
        existingBinding = flow.binding
        originalRuleId = flow.ruleId
        originalBindingId = flow.binding.id
        toKind = flow.binding.kind
        loadFormState(from: flow.binding.configuration)
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
            // One generic Markdown connection; the folder lives on this sync's
            // config, so bind to that single target rather than matching by path.
            toAccountId = ledger.markdownTargets.first?.id
            localMarkdown = MarkdownFormState(folderPath: cfg.folderPath, fileNameTemplate: cfg.fileNameTemplate,
                                              includeFrontmatter: cfg.includeFrontmatter)
        }
    }

    private func selectFolder(_ f: RmFolder) { folder = f; selectedFileIds = nil }

    private func selectDestination(_ app: ConnectedApp) {
        toKind = app.kind
        toAccountId = app.id
        switch app.kind {
        case .notion:     localNotion = NotionFormState(workspaceId: app.id)
        case .linear:     localLinear = LinearFormState(workspaceId: app.id)
        case .googleDocs: localGoogle = GoogleFormState(email: app.id)
        case .appleNotes: localAppleNotes = AppleNotesFormState()
        case .markdownFolder:
            if case .markdownFolder(let cfg) = app.defaultConfig {
                localMarkdown = MarkdownFormState(folderPath: cfg.folderPath, fileNameTemplate: cfg.fileNameTemplate, includeFrontmatter: cfg.includeFrontmatter)
            }
        }
    }

    private var destinationValid: Bool {
        switch toKind {
        case .notion:         return !localNotion.workspaceId.isEmpty && !localNotion.destinationId.isEmpty
        case .linear:         return !localLinear.workspaceId.isEmpty
        case .googleDocs:     return !localGoogle.email.isEmpty
        case .appleNotes:     return !localAppleNotes.folderName.isEmpty
        case .markdownFolder: return !localMarkdown.folderPath.isEmpty
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
                includeFrontmatter: localMarkdown.includeFrontmatter))
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
        guard let folder, let config = composedConfiguration() else { return }
        var binding = DestinationBinding(
            id: existingBinding?.id ?? UUID().uuidString,
            enabled: existingBinding?.enabled ?? true,
            configuration: config,
            createdAt: existingBinding?.createdAt ?? Date(),
            lastRunAt: existingBinding?.lastRunAt,
            lastRunStatus: existingBinding?.lastRunStatus ?? .neverRun,
            lastRunPagesSynced: existingBinding?.lastRunPagesSynced ?? 0,
            lastRunError: existingBinding?.lastRunError,
            ocrModeOverride: ocrMode,
            titleStrategyOverride: titleStrategy,
            requiredTags: requiredTags.isEmpty ? nil : requiredTags.sorted()
        )

        if let origRuleId = originalRuleId, let origBindingId = originalBindingId {
            let sameFolder = ledger.rule(forNotebookId: folder.id)?.id == origRuleId
            if sameFolder {
                applyRuleLevel(folderId: folder.id)
                ledger.updateBinding(ruleId: origRuleId, binding: binding)
                onClose(); return
            }
            ledger.removeBinding(ruleId: origRuleId, bindingId: origBindingId)
            if let old = ledger.rules.first(where: { $0.id == origRuleId }), old.destinations.isEmpty {
                ledger.deleteRule(id: origRuleId)
            }
        }
        addBinding(to: folder, binding)
        onClose()
    }

    private func addBinding(to folder: RmFolder, _ binding: DestinationBinding) {
        if let rule = ledger.rule(forNotebookId: folder.id) {
            applyRuleLevel(folderId: folder.id, base: rule)
            ledger.addBinding(ruleId: rule.id, binding: binding)
        } else {
            var rule = SyncRule.new(notebookId: folder.id, notebookName: folder.name)
            rule.selectedFileIds = selectedFileIds
            rule.pageOrder = pageOrder
            rule.savePdfAttachment = savePdf
            rule.destinations = [binding]
            ledger.upsertRule(rule)
        }
    }

    private func applyRuleLevel(folderId: String, base: SyncRule? = nil) {
        guard var rule = base ?? ledger.rule(forNotebookId: folderId) else { return }
        rule.selectedFileIds = selectedFileIds
        rule.pageOrder = pageOrder
        rule.savePdfAttachment = savePdf
        rule.updatedAt = Date()
        ledger.upsertRule(rule)
    }

    private func deleteSync() {
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
