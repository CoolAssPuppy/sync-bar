//
//  DestinationDetailScaffold.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

enum DestinationAuthorization {
    case none
    case keychainToken(title: String, description: String, keychainKey: KeychainStore.Key)
}

struct DestinationDetailScaffold: View {
    let kind: DestinationKind
    let title: String
    var subtitle: String?
    let connectedAt: Date?
    let activeBindings: [(SyncRule, DestinationBinding)]
    var authorization: DestinationAuthorization = .none
    /// Called when the user submits a rename via the header drawer.
    var rename: ((String) -> Void)? = nil
    /// reMarkable folders offered in the destination-first "Connect a folder" flow.
    var connectableFolders: [RmFolder] = []
    /// Routes the chosen folder to this destination. When nil, the connect action
    /// is hidden (the destination doesn't support destination-first connect yet).
    var connectSource: ((RmFolder) -> Void)? = nil
    let disconnect: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHeaderDrawerOpen = false
    @State private var renameValue: String = ""
    @FocusState private var renameFocused: Bool
    @State private var isPickingFolder = false
    @State private var editing: EditingBinding?

    /// A sync the user tapped to edit (rule + its binding to this destination).
    private struct EditingBinding: Identifiable {
        let rule: SyncRule
        let binding: DestinationBinding
        var id: String { binding.id }
    }

    /// Folders not already routed to this destination, so picking one always adds
    /// a real connection (rather than silently hitting the duplicate guard).
    private var availableFolders: [RmFolder] {
        let connected = Set(activeBindings.map { $0.0.rmNotebookId })
        return connectableFolders.filter { !connected.contains($0.id) }
    }

    private var canConnectFolder: Bool { connectSource != nil && !availableFolders.isEmpty }

    /// The source folder for a rule, used as the editor's context. Falls back to a
    /// stub from the rule's cached name if the live folder list isn't loaded.
    private func folder(for rule: SyncRule) -> RmFolder {
        Ledger.shared.folders.first(where: { $0.id == rule.rmNotebookId })
            ?? RmFolder(id: rule.rmNotebookId, name: rule.rmNotebookName,
                        parentFolder: nil, lastModified: Date(), pageCount: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            // Clip the drawer to this slot so its open/close slide stays below
            // the title bar instead of sliding up over/under the header.
            VStack(spacing: 0) {
                if isHeaderDrawerOpen {
                    VStack(spacing: 0) {
                        Divider().background(theme.divider)
                        headerDrawer
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipped()
            Divider().background(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    activeSyncsCard
                    if case .keychainToken(let title, let description, let key) = authorization {
                        authorizationCard(title: title, description: description, key: key)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .sheet(item: $editing) { target in
                BindingEditorSheet(
                    kind: target.binding.kind,
                    notebook: folder(for: target.rule),
                    existingBinding: target.binding,
                    onSave: { updated in
                        Ledger.shared.updateBinding(ruleId: target.rule.id, binding: updated)
                        editing = nil
                    },
                    onCancel: { editing = nil }
                )
            }
        }
        .background(theme.background)
        .animation(.easeOut(duration: 0.22), value: isHeaderDrawerOpen)
        .onChange(of: isHeaderDrawerOpen) { _, open in
            if open {
                renameValue = title
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    renameFocused = true
                }
            }
        }
        .sheet(isPresented: $isPickingFolder) {
            FolderPickerSheet(
                folders: availableFolders,
                onPick: { folder in
                    connectSource?(folder)
                    isPickingFolder = false
                },
                onCancel: { isPickingFolder = false }
            )
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(alignment: .center, spacing: 14) {
            DestinationIcon(kind: kind, size: 36)
                .roleBadge(.destination)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 18) {
                stat(label: "Active syncs", value: "\(activeBindings.count)")
                stat(label: "Pages synced", value: "\(totalPagesSynced)")
                stat(label: "Last run", value: lastRunLabel)
            }

            AppIconButton(systemName: isHeaderDrawerOpen ? "chevron.up" : "gearshape",
                          help: "Destination options") {
                isHeaderDrawerOpen.toggle()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.surface)
    }

    // MARK: Header drawer

    private var headerDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rename != nil {
                HStack(alignment: .center, spacing: 10) {
                    Text("RENAME")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.tertiary)
                        .frame(width: 92, alignment: .leading)
                    TextField("Name", text: $renameValue)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit(submitRename)
                    Button(action: submitRename) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.primary)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.cardInset))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Save name")
                    .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if case .keychainToken = authorization {
                HStack(alignment: .center, spacing: 10) {
                    Text("REAUTHORIZE")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.tertiary)
                        .frame(width: 92, alignment: .leading)
                    Text("Scroll to the Authorization card below to replace the token.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                    Spacer()
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Text("DELETE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.tertiary)
                    .frame(width: 92, alignment: .leading)
                Text("Removes this destination and any bindings that use it.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                Spacer()
                AppSecondaryButton(title: "Disconnect", systemImage: "minus.circle", tint: .destructive) {
                    disconnect()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.surface)
    }

    private func submitRename() {
        let trimmed = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rename else { return }
        rename(trimmed)
        isHeaderDrawerOpen = false
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.foreground)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.tertiary)
                .textCase(.uppercase)
        }
    }

    private var totalPagesSynced: Int {
        activeBindings.reduce(0) { $0 + $1.1.lastRunPagesSynced }
    }

    private var lastRunLabel: String {
        guard let latest = activeBindings.compactMap({ $0.1.lastRunAt }).max() else {
            return "Never"
        }
        return Formatters.relativeLabel(for: latest)
    }

    // MARK: Active syncs card

    @ViewBuilder
    private var activeSyncsCard: some View {
        // The trailing "Connect a folder" button is only for adding more once
        // syncs exist; when there are none, the empty state's own CTA covers it
        // (so we don't show two connect buttons).
        if canConnectFolder && !activeBindings.isEmpty {
            AppCard("Active Syncs", trailing: { connectFolderButton }) {
                activeSyncsContent
            }
        } else {
            AppCard("Active Syncs") { activeSyncsContent }
        }
    }

    @ViewBuilder
    private var activeSyncsContent: some View {
        if activeBindings.isEmpty {
            emptyActiveSyncs
        } else {
            VStack(spacing: 8) {
                ForEach(Array(activeBindings.enumerated()), id: \.offset) { _, pair in
                    ActiveSyncRow(rule: pair.0, binding: pair.1,
                                  onEdit: { editing = EditingBinding(rule: pair.0, binding: pair.1) })
                }
            }
        }
    }

    private var connectFolderButton: some View {
        AppSecondaryButton(title: "Connect a folder", systemImage: "plus") {
            isPickingFolder = true
        }
    }

    @ViewBuilder
    private var emptyActiveSyncs: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.tertiary)
            Text("Nothing flows here yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
            if canConnectFolder {
                Text("Connect a reMarkable folder to start sending notes here.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                AppPrimaryButton(title: "Connect a reMarkable folder", systemImage: "plus") {
                    isPickingFolder = true
                }
                .padding(.top, 2)
            } else {
                Text("No reMarkable folders to connect yet. Pair and sync your reMarkable, then connect a folder here.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func authorizationCard(title: String, description: String, key: KeychainStore.Key) -> some View {
        AppCard("Authorization") {
            VStack(alignment: .leading, spacing: 10) {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                TokenField(title: title, keychainKey: key)
            }
        }
    }
}

// MARK: - Active sync row

struct ActiveSyncRow: View {
    let rule: SyncRule
    let binding: DestinationBinding
    var onEdit: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardElevated)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primary)
                }
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.borderStrong, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.rmNotebookName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    Text(secondaryLine)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusPill

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(isHovered ? theme.cardElevated : theme.cardInset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Edit \(binding.kind.label) destination")
    }

    private var secondaryLine: String {
        if let error = binding.lastRunError, !error.isEmpty { return error }
        if let lastRun = binding.lastRunAt {
            return "\(Formatters.syncResultLabel(pageCount: binding.lastRunPagesSynced)) · \(Formatters.relativeLabel(for: lastRun))"
        }
        return "Never run"
    }

    @ViewBuilder
    private var statusPill: some View {
        if !binding.enabled {
            StatusPill(label: "Off", kind: .neutral)
        } else {
            switch binding.lastRunStatus {
            case .success:  StatusPill(label: "Synced", kind: .success)
            case .partial:  StatusPill(label: "Partial", kind: .warning)
            case .error:    StatusPill(label: "Failed", kind: .destructive)
            case .running:  StatusPill(label: "Running", kind: .info)
            case .neverRun: StatusPill(label: "New", kind: .neutral)
            }
        }
    }
}

// MARK: - Reusable token field

struct TokenField: View {
    let title: String
    let keychainKey: KeychainStore.Key

    @Environment(\.theme) private var theme
    @State private var value: String = ""
    @State private var hasValue: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            SecureField(hasValue ? "Token saved" : "Paste token…", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            AppSecondaryButton(title: hasValue ? "Replace" : "Save", systemImage: "checkmark") {
                KeychainStore.shared.set(value: value, for: keychainKey)
                value = ""
                hasValue = true
            }
            if hasValue {
                AppSecondaryButton(title: "Clear", tint: .destructive) {
                    KeychainStore.shared.delete(key: keychainKey)
                    hasValue = false
                }
            }
        }
        .onAppear {
            hasValue = !(KeychainStore.shared.value(for: keychainKey) ?? "").isEmpty
        }
    }
}
