//
//  ConnectionsView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Where sources and destinations are set up. Rarely visited: pair the
//  reMarkable, connect apps, reconnect/disconnect. Syncs reference these.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConnectionsView: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var isAddingApp = false
    @State private var isAddingSource = false
    @State private var isRepairing = false
    @State private var isConfirmingRemarkableDisconnect = false
    @State private var linearTeamChoices: LinearTeamChoices?
    @State private var safariHasAccess = false
    @State private var remindersHasAccess = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceSection
                    appsSection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
        .background(theme.background)
        .onAppear { refreshAccessStatus() }
        .sheet(isPresented: $isAddingApp) { AddDestinationSheet(isPresented: $isAddingApp) }
        .sheet(isPresented: $isAddingSource, onDismiss: { refreshAccessStatus() }) {
            AddSourceSheet(isPresented: $isAddingSource)
        }
        .sheet(isPresented: $isRepairing) {
            RemarkablePairPanel(title: "Re-pair your reMarkable", onClose: { isRepairing = false })
        }
        .sheet(item: $linearTeamChoices) { choices in
            LinearTeamPickerSheet(
                teams: choices.teams,
                preselected: Set(ledger.linearAccounts.map(\.id)),
                onConfirm: { ledger.applyLinearTeamSelection(available: choices.teams, selectedIds: $0); linearTeamChoices = nil },
                onCancel: { linearTeamChoices = nil }
            )
        }
        .confirmationDialog("Disconnect reMarkable?", isPresented: $isConfirmingRemarkableDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { ledger.disconnectRemarkable() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(remarkableDisconnectWarning)
        }
    }

    /// Spells out the blast radius before disconnecting reMarkable: it's the
    /// source for every reMarkable sync, so disconnecting removes all of them.
    /// Destinations and other sources (Safari, Reminders) are left untouched.
    private var remarkableDisconnectWarning: String {
        let count = ledger.rules.filter { $0.remarkableConfig != nil }.count
        let syncs = count == 0
            ? "This removes the pairing and its folders."
            : "This removes the pairing and \(count) reMarkable sync\(count == 1 ? "" : "s")."
        return "\(syncs) Your destinations and other sources stay connected. You can re-pair anytime."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connections")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.foreground)
            Text("Your data, wherever it is and needs to go")
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 14)
    }

    // MARK: Section header with add control

    /// A section header (e.g. "Sources") with a right-aligned "+" affordance.
    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            SectionLabel(text: title)
            Spacer()
            trailing()
        }
    }

    /// The "+" glyph in the normal foreground color, used to add a source/destination.
    private var addGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.foreground)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Sources") {
                Button(action: { isAddingSource = true }) { addGlyph }.buttonStyle(.plain)
            }
            if ledger.remarkableAccount == nil && !ledger.safariConnected
                && !ledger.remindersConnected && ledger.xAccounts.isEmpty {
                Text("No sources yet. Add one with the + above.")
                    .font(.system(size: 13)).foregroundStyle(theme.muted).padding(.vertical, 4)
            }
            if ledger.remarkableAccount != nil {
                ConnectionCard(
                    icon: { AnyView(SourceIcon(size: 38)) },
                    title: "reMarkable",
                    subtitle: sourceSubtitle,
                    status: sourceStatus,
                    trailing: {
                        AnyView(AppActionMenu(actions: [
                            AppMenuAction(title: "Upload files", systemImage: "arrow.up.doc") { presentUploadPanel() },
                            AppMenuAction(title: "Re-pair", systemImage: "qrcode.viewfinder") { isRepairing = true },
                            AppMenuAction(title: "Disconnect", systemImage: "minus.circle", isDestructive: true) { isConfirmingRemarkableDisconnect = true }
                        ]))
                    }
                )
            }
            if ledger.safariConnected {
                ConnectionCard(
                    icon: { AnyView(SourceIcon(kind: .safari, size: 38)) },
                    title: "Safari",
                    subtitle: safariHasAccess ? "Connected · bookmarks" : "Needs Full Disk Access to read bookmarks",
                    status: safariHasAccess ? .connected : .error,
                    trailing: {
                        AnyView(AppActionMenu(actions: safariActions))
                    }
                )
            }
            if ledger.remindersConnected {
                ConnectionCard(
                    icon: { AnyView(remindersGlyph) },
                    title: "Reminders",
                    subtitle: remindersHasAccess ? "Connected · two-way with Notion" : "Needs Reminders access",
                    status: remindersHasAccess ? .connected : .error,
                    trailing: {
                        AnyView(AppActionMenu(actions: remindersActions))
                    }
                )
            }
            ForEach(ledger.xAccounts) { account in
                ConnectionCard(
                    icon: { AnyView(SourceIcon(kind: .x, size: 38)) },
                    title: account.handle,
                    subtitle: xSubtitle(account),
                    status: .connected,
                    trailing: { AnyView(AppActionMenu(actions: xActions(account))) }
                )
            }
        }
    }

    private func xSubtitle(_ account: XAccount) -> String {
        let streams = account.selectedStreams.map(\.label).joined(separator: ", ")
        let count = ledger.rules.filter { if case .x(let c) = $0.source { return c.accountId == account.id }; return false }.count
        let base = streams.isEmpty ? "Connected" : "Connected · \(streams)"
        return count == 0 ? base : "\(base) · \(count) sync\(count == 1 ? "" : "s")"
    }

    private func xActions(_ account: XAccount) -> [AppMenuAction] {
        [
            AppMenuAction(title: "Reconnect", systemImage: "arrow.clockwise") {
                Task { await reconnect { ledger.upsertXAccount(try await XAuthService.shared.connect(streams: account.selectedStreams)) } }
            },
            AppMenuAction(title: "Disconnect", systemImage: "minus.circle", isDestructive: true) {
                ledger.removeXAccount(id: account.id)
            }
        ]
    }

    private var safariActions: [AppMenuAction] {
        var actions: [AppMenuAction] = []
        if !safariHasAccess {
            actions.append(AppMenuAction(title: "Open Settings", systemImage: "gearshape") { FullDiskAccessProbe.openSystemSettings() })
            actions.append(AppMenuAction(title: "Re-check", systemImage: "arrow.clockwise") { safariHasAccess = FullDiskAccessProbe.hasAccess() })
        }
        actions.append(AppMenuAction(title: "Disconnect", systemImage: "minus.circle", isDestructive: true) { ledger.setSafariConnected(false) })
        return actions
    }

    private var remindersActions: [AppMenuAction] {
        var actions: [AppMenuAction] = []
        if remindersHasAccess {
            actions.append(AppMenuAction(title: "Re-check access", systemImage: "arrow.clockwise") { refreshAccessStatus() })
        } else {
            actions.append(AppMenuAction(title: "Grant access", systemImage: "checklist") { requestRemindersAccess() })
        }
        actions.append(AppMenuAction(title: "Disconnect", systemImage: "minus.circle", isDestructive: true) { ledger.setRemindersConnected(false) })
        return actions
    }

    private var remindersGlyph: some View {
        Image("Reminders").resizable().interpolation(.high).scaledToFit().frame(width: 38, height: 38)
    }

    private func refreshAccessStatus() {
        safariHasAccess = FullDiskAccessProbe.hasAccess()
        remindersHasAccess = EventKitRemindersClient().authorizationGranted()
    }

    private func requestRemindersAccess() {
        Task {
            _ = await EventKitRemindersClient().requestAccess()
            await MainActor.run { remindersHasAccess = EventKitRemindersClient().authorizationGranted() }
        }
    }

    private var sourceSubtitle: String {
        guard ledger.remarkableAccount != nil else { return "Not paired" }
        if ledger.remarkableNeedsRepair { return "Token rejected — re-pair to reconnect" }
        let folders = ledger.folders.count
        return "Connected · \(folders) folder\(folders == 1 ? "" : "s")"
    }

    private var sourceStatus: ConnectionStatus {
        if ledger.remarkableAccount == nil { return .none }
        return ledger.remarkableNeedsRepair ? .error : .connected
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Destinations") {
                Button(action: { isAddingApp = true }) { addGlyph }.buttonStyle(.plain)
            }
            if !ledger.hasAnyDestination {
                Text("No destinations connected yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
                    .padding(.vertical, 4)
            }
            ForEach(ledger.notionWorkspaces) { ws in
                appCard(kind: .notion, name: ws.workspaceName, subtitle: notionSubtitle(ws),
                        matches: { if case .notion(let c) = $0 { return c.workspaceId == ws.id }; return false },
                        rename: { ledger.renameNotionWorkspace(id: ws.id, newName: $0) },
                        reconnect: { await reconnect { ledger.upsertNotionWorkspace(try await NotionAuthService.shared.connect()) } },
                        disconnect: { ledger.removeNotionWorkspace(id: ws.id) })
            }
            ForEach(ledger.linearAccounts) { acct in
                appCard(kind: .linear, name: acct.name, subtitle: acct.organizationName ?? "Linear",
                        matches: { if case .linear(let c) = $0 { return c.workspaceId == acct.id }; return false },
                        rename: { ledger.renameLinearAccount(id: acct.id, newName: $0) },
                        reconnect: { await reconnect { linearTeamChoices = LinearTeamChoices(teams: try await LinearAuthService.shared.connect()) } },
                        disconnect: { ledger.removeLinearAccount(id: acct.id) })
            }
            ForEach(ledger.googleAccounts) { acct in
                appCard(kind: .googleDocs, name: acct.displayName, subtitle: acct.id,
                        matches: { if case .googleDocs(let c) = $0 { return c.accountEmail == acct.id }; return false },
                        rename: { ledger.renameGoogleAccount(id: acct.id, newName: $0) },
                        reconnect: { await reconnect { ledger.upsertGoogleAccount(try await GoogleAuthService.shared.connect()) } },
                        disconnect: { ledger.removeGoogleAccount(id: acct.id) })
            }
            ForEach(ledger.markdownTargets) { target in
                appCard(kind: .markdownFolder, name: target.displayName,
                        subtitle: target.folderPath.isEmpty ? "Local Markdown files"
                            : (target.folderPath as NSString).abbreviatingWithTildeInPath,
                        matches: { if case .markdownFolder = $0 { return true }; return false },
                        rename: nil, reconnect: nil,
                        disconnect: { ledger.removeMarkdownTarget(id: target.id) })
            }
            ForEach(ledger.appleNotesTargets) { target in
                appCard(kind: .appleNotes, name: "Apple Notes", subtitle: "iCloud Notes",
                        matches: { if case .appleNotes = $0 { return true }; return false },
                        rename: nil, reconnect: nil,
                        disconnect: { ledger.removeAppleNotesTarget(id: target.id) })
            }
            ForEach(ledger.chromeTargets) { target in
                appCard(kind: .chrome, name: "Chrome", subtitle: "Profile: \(target.profileDirName)",
                        matches: { if case .chrome = $0 { return true }; return false },
                        rename: nil, reconnect: nil,
                        disconnect: { ledger.removeChromeTarget(id: target.id) })
            }
        }
    }

    private func notionSubtitle(_ ws: NotionWorkspace) -> String { ws.workspaceName }

    private func appCard(kind: DestinationKind, name: String, subtitle: String,
                         matches: @escaping (DestinationConfiguration) -> Bool,
                         rename: ((String) -> Void)?,
                         reconnect: (() async -> Void)?,
                         disconnect: @escaping () -> Void) -> some View {
        let count = ledger.bindings(matching: matches).count
        let detail = count == 0 ? subtitle : "\(subtitle) · \(count) sync\(count == 1 ? "" : "s")"
        return ConnectionCard(
            icon: { AnyView(DestinationIcon(kind: kind, size: 32)) },
            title: name,
            subtitle: detail,
            status: count > 0 ? .connected : .idle,
            trailing: {
                var actions: [AppMenuAction] = []
                if let reconnect {
                    actions.append(AppMenuAction(title: "Reconnect", systemImage: "arrow.clockwise") { Task { await reconnect() } })
                }
                actions.append(AppMenuAction(title: "Disconnect", systemImage: "minus.circle", isDestructive: true, action: disconnect))
                return AnyView(AppActionMenu(actions: actions))
            }
        )
    }

    // MARK: Actions

    @MainActor
    private func reconnect(_ work: @escaping () async throws -> Void) async {
        do { try await work() }
        catch OAuthError.userCancelled { /* ignore */ }
        catch { Log.ui.error("Reconnect failed: \(String(describing: error), privacy: .public)") }
    }

    private func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .epub]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        panel.message = "Choose PDF or EPUB files to upload to reMarkable (My Files)."
        panel.begin { response in
            guard response == .OK else { return }
            UploadCoordinator.shared.upload(urls: panel.urls, toFolderId: "")
        }
    }
}

// MARK: - Connection card

enum ConnectionStatus { case connected, idle, error, none }

struct ConnectionCard: View {
    let icon: () -> AnyView
    let title: String
    let subtitle: String
    let status: ConnectionStatus
    let trailing: () -> AnyView

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 7) {
                    if status != .none, let dot = statusDot {
                        Circle().fill(dot).frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    private var statusDot: Color? {
        switch status {
        case .connected: return theme.success
        case .idle:      return theme.tertiary
        case .error:     return theme.destructive
        case .none:      return nil
        }
    }
}
