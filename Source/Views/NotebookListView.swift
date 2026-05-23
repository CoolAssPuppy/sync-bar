//
//  NotebookListView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct NotebookListView: View {
    @Binding var selectedNotebookId: String?
    @ObservedObject var coordinator: SyncCoordinator
    var onRefresh: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.theme) private var theme

    /// Folders to render. Hides the synthetic "Unfiled" folder when the user has
    /// chosen to ignore loose notes. Display-only: sync runs off rules, not this
    /// list, so an ignored Unfiled folder with a rule keeps syncing.
    private var visibleNotebooks: [RmFolder] {
        guard settings.ignoreUnfiledNotes else { return ledger.folders }
        return ledger.folders.filter { $0.id != unfiledFolderId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.divider)

            if ledger.remarkableAccount == nil {
                pairPrompt
            } else if visibleNotebooks.isEmpty {
                emptyState
            } else {
                listAndSheet
            }
        }
        .background(theme.background)
        .onAppear {
            if let id = selectedNotebookId, !visibleNotebooks.contains(where: { $0.id == id }) {
                selectedNotebookId = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            sourceIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("Folders")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()

            AppIconButton(systemName: "arrow.clockwise", help: "Refresh folders", spinOnTap: true) {
                onRefresh()
            }
            AppIconButton(systemName: "arrow.triangle.2.circlepath",
                          help: "Sync all rules now",
                          tint: ledger.rules.isEmpty ? .foreground : .primary,
                          spinOnTap: true) {
                if !ledger.rules.isEmpty { coordinator.syncNow(ruleId: nil) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// The reMarkable source mark, sized and laid out to match a destination's
    /// detail-header icon (DestinationIcon at 36pt), so sources and destinations
    /// read as peers. Template-tinted so the mark stays visible on any theme.
    private var sourceIcon: some View {
        Image("Remarkable")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(theme.foreground)
            .frame(width: 36, height: 36)
    }

    private var headerSubtitle: String {
        if ledger.remarkableAccount == nil {
            return "Pair your reMarkable to see folders"
        }
        let total = visibleNotebooks.count
        let synced = ledger.rules.count
        return "\(total) folder\(total == 1 ? "" : "s") · \(synced) rule\(synced == 1 ? "" : "s")"
    }

    // MARK: Pair / empty states

    private var pairPrompt: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.card)
                Image(systemName: "pencil.tip.crop.circle.badge.plus")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 96, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )

            VStack(spacing: 6) {
                Text("Connect Your reMarkable")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Sign in at my.remarkable.com, generate an 8-character one-time code, and paste it here to start syncing notes to Notion.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 10) {
                AppPrimaryButton(title: "Pair reMarkable", systemImage: "qrcode.viewfinder") {
                    NotificationCenter.default.post(name: .openPairRemarkable, object: nil)
                }
                AppSecondaryButton(title: "I'll do this later") {
                    NotificationCenter.default.post(name: .openAddNotionWorkspace, object: nil)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.muted)
            Text("No Folders Found")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("Create a folder on your reMarkable and put your notes inside it, then refresh.")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
            AppSecondaryButton(title: "Refresh", systemImage: "arrow.clockwise", action: onRefresh)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List + right-edge slider

    private var listAndSheet: some View {
        ZStack(alignment: .trailing) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleNotebooks) { notebook in
                        NotebookRow(
                            notebook: notebook,
                            rule: ledger.rule(forNotebookId: notebook.id),
                            isSelected: selectedNotebookId == notebook.id,
                            onIgnore: notebook.id == unfiledFolderId
                                ? {
                                    settings.ignoreUnfiledNotes = true
                                    if selectedNotebookId == unfiledFolderId { selectedNotebookId = nil }
                                }
                                : nil
                        )
                        .onTapGesture { selectNotebook(notebook) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notebookId = selectedNotebookId,
               let notebook = visibleNotebooks.first(where: { $0.id == notebookId }) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { closeSheet() }
                    .transition(.opacity)
                RuleSliderView(
                    notebook: notebook,
                    coordinator: coordinator,
                    onClose: { closeSheet() },
                    onSyncNow: { ruleId, bindingId in
                        coordinator.syncNow(ruleId: ruleId, bindingId: bindingId)
                    }
                )
                .frame(width: 480)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: selectedNotebookId)
    }

    private func selectNotebook(_ notebook: RmFolder) {
        selectedNotebookId = notebook.id
    }

    private func closeSheet() {
        selectedNotebookId = nil
    }
}

// MARK: - Notebook row

private struct NotebookRow: View {
    let notebook: RmFolder
    let rule: SyncRule?
    let isSelected: Bool
    /// Provided only for the synthetic "Unfiled" folder, surfacing a faint "x"
    /// that hides it from the list (re-enable in Settings → Folder visibility).
    var onIgnore: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.card)
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.borderStrong, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(notebook.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 6) {
                    if let folder = notebook.parentFolder {
                        Text(folder)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.tertiary)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiary)
                    }
                    Text("\(notebook.pageCount) note\(notebook.pageCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiary)
                    Text("Modified \(Formatters.relativeLabel(for: notebook.lastModified))")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                }
            }

            Spacer(minLength: 12)

            statusPill

            if let onIgnore {
                ignoreButton(onIgnore)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// Faint dismiss control shown only on the Unfiled folder row.
    private func ignoreButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.tertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 0.9 : 0.4)
        .help("Ignore Unfiled notes (turn back on in Settings)")
    }

    private var rowBackgroundColor: Color {
        if isSelected { return theme.primary.opacity(0.08) }
        if isHovered  { return theme.cardElevated.opacity(0.6) }
        return theme.card
    }

    private var rowBorder: Color {
        if isSelected { return theme.primary.opacity(0.35) }
        return theme.border
    }

    @ViewBuilder
    private var statusPill: some View {
        if let rule, !rule.destinations.isEmpty {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(rule.destinations.count) destination\(rule.destinations.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.muted)
                if !rule.enabled {
                    Text("Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.tertiary)
                } else if let lastRun = rule.aggregateLastRunAt {
                    Text("Synced \(Formatters.relativeLabel(for: lastRun))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(syncColor(rule))
                } else {
                    Text("Not synced yet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.tertiary)
                }
            }
        } else if rule != nil {
            Text("Draft")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.tertiary)
        } else {
            Text("No rule")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.tertiary)
        }
    }

    private func syncColor(_ rule: SyncRule) -> Color {
        switch rule.aggregateLastRunStatus {
        case .success:  return theme.success
        case .partial:  return theme.warning
        case .error:    return theme.destructive
        case .running:  return theme.primary
        case .neverRun: return theme.muted
        }
    }
}
