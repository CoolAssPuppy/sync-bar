//
//  SyncEditorView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The one place a Sync is created or edited: From a folder, To an app, How.
//  Maps the single "Sync" object onto the underlying rule + binding.
//

import SwiftUI

enum SyncEditorTarget: Identifiable {
    case new
    case edit(SyncFlow)
    var id: String { if case .edit(let f) = self { return f.id }; return "new" }
}

/// A connected destination account, normalized for the editor's "To" chips.
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
    @State private var config: DestinationConfiguration?
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

    // sheets
    @State private var isAddingApp = false
    @State private var isConfiguring = false
    @State private var isChoosingScope = false
    @State private var scopeFiles: [RmFile] = []
    @State private var scopeLoading = false

    private var isEditing: Bool { originalBindingId != nil }
    private var canSave: Bool { folder != nil && config != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fromStep
                    toStep
                    howStep
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 680, height: 720)
        .background(theme.surface)
        .environment(\.theme, theme)
        .onAppear(perform: load)
        .sheet(isPresented: $isAddingApp) { AddDestinationSheet(isPresented: $isAddingApp) }
        .sheet(isPresented: $isConfiguring) { configureSheet }
        .sheet(isPresented: $isChoosingScope) { scopeSheet }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "Edit sync" : "New sync").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.foreground)
                Text("From a folder, to an app, synced how.").font(.system(size: 12.5)).foregroundStyle(theme.muted)
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
            PillButton(title: "Save sync", action: save)
                .opacity(canSave ? 1 : 0.5)
                .disabled(!canSave)
        }
        .padding(20)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
        .background(theme.background)
    }

    // MARK: From

    private var fromStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("FROM", "which reMarkable folder")
            HStack(spacing: 12) {
                FolderGlyph(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Menu {
                        ForEach(ledger.folders) { f in Button(f.name) { selectFolder(f) } }
                    } label: {
                        HStack(spacing: 6) {
                            Text(folder?.name ?? "Choose a folder")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(folder == nil ? theme.muted : theme.foreground)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.muted)
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Text(scopeSummary).font(.system(size: 12)).foregroundStyle(theme.muted)
                }
                Spacer()
                if folder != nil {
                    AppSecondaryButton(title: "Choose notebooks") { openScope() }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
    }

    private var scopeSummary: String {
        guard folder != nil else { return "Pick the folder to sync" }
        guard let ids = selectedFileIds, !ids.isEmpty else { return "Syncing every notebook" }
        return "Syncing \(ids.count) selected notebook\(ids.count == 1 ? "" : "s")"
    }

    // MARK: To

    private var toStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("TO", "pick a connected app, or connect a new one")
            FlowLayout(spacing: 9) {
                ForEach(ledger.connectedApps) { app in appChip(app) }
                connectChip
            }
            if config != nil, folder != nil {
                AppSecondaryButton(title: "Configure \(config!.kind.label)…", systemImage: "slider.horizontal.3") { isConfiguring = true }
            }
        }
    }

    private func appChip(_ app: ConnectedApp) -> some View {
        let selected = config?.kind == app.kind && configMatches(app)
        return Button(action: { selectApp(app) }) {
            HStack(spacing: 8) {
                DestinationIcon(kind: app.kind, size: 22)
                Text(app.name).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? theme.foreground : theme.foregroundSoft).lineLimit(1)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.primary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.primary.opacity(0.08) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? theme.primary : theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var connectChip: some View {
        Button(action: { isAddingApp = true }) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.primary)
                Text("Connect new app").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.primary)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(theme.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: How

    private var howStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("HOW", "every option for this sync, in one place")
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
                        HStack(spacing: 6) {
                            Text(pageOrder == .chronological ? "Chronological" : "Reverse").font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.muted)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                rowDivider
                optionRow("Only notes tagged", align: .top) {
                    RequiredTagsControl(requiredTags: $requiredTags)
                }
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

    @ViewBuilder private var configureSheet: some View {
        if let folder, let config {
            BindingEditorSheet(
                kind: config.kind,
                notebook: folder,
                existingBinding: DestinationBinding(configuration: config),
                onSave: { binding in self.config = binding.configuration; isConfiguring = false },
                onCancel: { isConfiguring = false }
            )
        }
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
        config = flow.binding.configuration
        titleStrategy = flow.titleStrategy
        ocrMode = flow.ocrMode
        pageOrder = flow.rule.pageOrder
        savePdf = flow.rule.savePdfAttachment
        requiredTags = flow.requiredTags
        existingBinding = flow.binding
        originalRuleId = flow.ruleId
        originalBindingId = flow.binding.id
    }

    private func selectFolder(_ f: RmFolder) { folder = f; selectedFileIds = nil }

    private func selectApp(_ app: ConnectedApp) {
        config = app.defaultConfig
    }

    private func configMatches(_ app: ConnectedApp) -> Bool {
        guard let config else { return false }
        switch (config, app.defaultConfig) {
        case (.notion(let a), .notion(let b)): return a.workspaceId == b.workspaceId
        case (.linear(let a), .linear(let b)): return a.workspaceId == b.workspaceId
        case (.googleDocs(let a), .googleDocs(let b)): return a.accountEmail == b.accountEmail
        case (.markdownFolder(let a), .markdownFolder(let b)): return a.folderPath == b.folderPath
        case (.appleNotes, .appleNotes): return true
        default: return false
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
        guard let folder, let config else { return }
        var binding = existingBinding ?? DestinationBinding(configuration: config)
        binding.configuration = config
        binding.titleStrategyOverride = titleStrategy
        binding.ocrModeOverride = ocrMode
        binding.requiredTags = requiredTags.isEmpty ? nil : requiredTags
        binding.enabled = true

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

// MARK: - Simple wrap layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
