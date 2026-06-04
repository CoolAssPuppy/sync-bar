//
//  NotebookListView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NotebookListView: View {
    @Binding var selectedNotebookId: String?
    @ObservedObject var coordinator: SyncCoordinator
    var onRefresh: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.theme) private var theme

    @State private var isRepairDrawerOpen = false
    @State private var repairCode = ""
    @State private var isRepairing = false
    @State private var repairError: String?
    @State private var isRootDropTargeted = false

    private let remarkable = RealRemarkableClient()

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
            // Clip the re-pair drawer to this slot so its open/close fade stays
            // below the header, mirroring DestinationDetailScaffold.
            VStack(spacing: 0) {
                if isRepairDrawerOpen {
                    VStack(spacing: 0) {
                        Divider().background(theme.divider)
                        repairDrawer
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
            Divider().background(theme.divider)

            if ledger.remarkableNeedsRepair {
                disconnectedBanner
            }

            if ledger.remarkableAccount == nil {
                pairPrompt
            } else if visibleNotebooks.isEmpty {
                emptyState
            } else {
                listAndSheet
            }
        }
        .background(theme.background)
        .animation(.easeOut(duration: 0.22), value: isRepairDrawerOpen)
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
                Text("reMarkable Folders")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()

            AppIconButton(systemName: isRepairDrawerOpen ? "chevron.up" : "gearshape",
                          help: "Re-pair reMarkable") {
                isRepairDrawerOpen.toggle()
            }
            AppIconButton(systemName: "arrow.up.doc",
                          help: "Upload PDF/EPUB to reMarkable") {
                presentUploadPanel()
            }
            AppIconButton(systemName: "arrow.triangle.2.circlepath",
                          help: "Refresh & sync all rules now",
                          tint: ledger.rules.isEmpty ? .foreground : .primary,
                          spinOnTap: true) {
                onRefresh()
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
        // The reMarkable mark ships as an opaque (no-alpha) black-on-white PNG, so
        // template tinting would flatten it to a solid square. Render it as-is on
        // a small white chip so it stays legible on any theme.
        Image("Remarkable")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(5)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .roleBadge(.source)
    }

    // MARK: Disconnected banner

    /// Shown when the cloud has rejected the device token. Cached folders stay
    /// visible; this surfaces that syncs/uploads are failing and offers re-pair.
    private var disconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.destructive)
            VStack(alignment: .leading, spacing: 1) {
                Text("reMarkable disconnected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Your device token was rejected. Re-pair to resume syncing and uploads.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 12)
            AppSecondaryButton(title: "Re-Pair", systemImage: "qrcode.viewfinder", tint: .destructive) {
                isRepairDrawerOpen = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(theme.destructive.opacity(0.08))
        .overlay(alignment: .bottom) { Divider().background(theme.divider) }
    }

    // MARK: Re-pair drawer

    /// Drops down from the header (gear icon) so a user whose reMarkable account
    /// was deleted/recreated can pair a fresh device token in place, without
    /// having to wipe the local account first.
    private var repairDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Re-Pair Your reMarkable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("Generate a fresh 8-character code at my.remarkable.com → Connect, then enter it here.")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)

            HStack(spacing: 12) {
                CodeBoxField(value: $repairCode, length: 8)
                Spacer(minLength: 12)
                AppSecondaryButton(title: "Cancel") { closeRepairDrawer() }
                AppPrimaryButton(
                    title: isRepairing ? "Re-Pairing…" : "Re-Pair",
                    systemImage: "qrcode.viewfinder",
                    isDisabled: repairCode.count != 8 || isRepairing
                ) {
                    Task { await repair() }
                }
            }

            if let repairError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.destructive)
                    Text(repairError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.destructive)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.surface)
    }

    private func repair() async {
        isRepairing = true
        repairError = nil
        defer { isRepairing = false }
        do {
            let account = try await remarkable.pairDevice(oneTimeCode: repairCode)
            // Drop the stale derived session token so it re-derives against the
            // new device token on the next sync.
            KeychainStore.shared.delete(key: .remarkableUserToken)
            ledger.setRemarkableAccount(account)
            ledger.setFolders(try await remarkable.listFolders())
            ledger.updateRemarkableHealth(error: nil)   // reconnected
            Telemetry.capture("remarkable.repaired")
            repairCode = ""
            isRepairDrawerOpen = false
        } catch {
            Telemetry.capture("remarkable.repair_failed")
            repairError = Formatters.userMessage(for: error)
        }
    }

    private func closeRepairDrawer() {
        isRepairDrawerOpen = false
        repairError = nil
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
            Text("Create a folder on your reMarkable and put your notes inside it, then refresh. Or drop a PDF/EPUB here to upload it to My Files.")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            AppSecondaryButton(title: "Refresh", systemImage: "arrow.clockwise", action: onRefresh)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            uploadToRoot(urls)
            return true
        } isTargeted: { isRootDropTargeted = $0 }
        .overlay(rootDropHighlight)
    }

    /// Accent-colored inset border shown while files are dragged over the root
    /// (My Files) drop area.
    @ViewBuilder
    private var rootDropHighlight: some View {
        if isRootDropTargeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.primary, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(10)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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
                                : nil,
                            onDropFiles: { urls in
                                UploadCoordinator.shared.upload(urls: urls, toFolderId: notebook.id)
                            }
                        )
                        .onTapGesture { selectNotebook(notebook) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Files dropped on the empty area beneath the rows go to the root.
            // A drop on a folder row is consumed by the row first (innermost wins).
            .dropDestination(for: URL.self) { urls, _ in
                uploadToRoot(urls)
                return true
            } isTargeted: { isRootDropTargeted = $0 }
            .overlay(rootDropHighlight)

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

    // MARK: Upload

    /// Opens a PDF/EPUB picker; chosen files upload to the root ("My Files").
    private func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .epub]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Upload"
        panel.message = "Choose PDF or EPUB files to upload to reMarkable (My Files)."
        panel.begin { response in
            guard response == .OK else { return }
            UploadCoordinator.shared.upload(urls: panel.urls, toFolderId: "")
        }
    }

    /// Routes files dropped on empty space (not on a folder row) to the root.
    private func uploadToRoot(_ urls: [URL]) {
        UploadCoordinator.shared.upload(urls: urls, toFolderId: "")
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
    /// Files dropped onto this row, to upload into this folder.
    var onDropFiles: ([URL]) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isDropTargeted = false

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
                    Text("\(notebook.pageCount) Notebook\(notebook.pageCount == 1 ? "" : "s")")
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
        .dropDestination(for: URL.self) { urls, _ in
            onDropFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
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
        if isDropTargeted { return theme.primary.opacity(0.16) }
        if isSelected { return theme.primary.opacity(0.08) }
        if isHovered  { return theme.cardElevated.opacity(0.6) }
        return theme.card
    }

    private var rowBorder: Color {
        if isDropTargeted { return theme.primary }
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
