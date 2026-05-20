//
//  BindingEditorSheet.swift
//  SyncBar
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
        case .googleDocs:     GoogleDocsForm(binding: $localGoogle)
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
