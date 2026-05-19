//
//  DetailViews.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

// MARK: - Notion workspace

struct NotionWorkspaceDetailView: View {
    let workspaceId: String
    @ObservedObject private var ledger = Ledger.shared

    private var workspace: NotionWorkspace? {
        ledger.notionWorkspaces.first(where: { $0.id == workspaceId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .notion,
            title: workspace?.workspaceName ?? "Workspace",
            connectedAt: workspace?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .notion(let cfg) = config { return cfg.workspaceId == workspaceId }
                return false
            }),
            rename: { newName in ledger.renameNotionWorkspace(id: workspaceId, newName: newName) },
            disconnect: { ledger.removeNotionWorkspace(id: workspaceId) }
        )
    }
}

// MARK: - Linear account

struct LinearAccountDetailView: View {
    let accountId: String
    @ObservedObject private var ledger = Ledger.shared

    private var account: LinearAccount? {
        ledger.linearAccounts.first(where: { $0.id == accountId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .linear,
            title: account?.name ?? "Linear team",
            subtitle: account?.organizationName,
            connectedAt: account?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .linear(let cfg) = config { return cfg.workspaceId == accountId }
                return false
            }),
            authorization: .keychainToken(
                title: "Linear access token",
                description: "Personal access token from linear.app/settings/account/security. Without one, SyncNerds writes via a mock that returns a synthetic identifier.",
                keychainKey: .linearAccessToken
            ),
            rename: { newName in ledger.renameLinearAccount(id: accountId, newName: newName) },
            disconnect: { ledger.removeLinearAccount(id: accountId) }
        )
    }
}

// MARK: - Google Docs account

struct GoogleAccountDetailView: View {
    let accountId: String
    @ObservedObject private var ledger = Ledger.shared

    private var account: GoogleAccount? {
        ledger.googleAccounts.first(where: { $0.id == accountId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .googleDocs,
            title: account?.displayName ?? "Google account",
            subtitle: account?.id,
            connectedAt: account?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .googleDocs(let cfg) = config { return cfg.accountEmail == accountId }
                return false
            }),
            authorization: .keychainToken(
                title: "Google access token",
                description: "OAuth access token with Drive + Docs scopes. Without one, SyncNerds returns a synthetic doc URL.",
                keychainKey: .googleAccessToken(email: accountId)
            ),
            rename: { newName in ledger.renameGoogleAccount(id: accountId, newName: newName) },
            disconnect: { ledger.removeGoogleAccount(id: accountId) }
        )
    }
}

// MARK: - Markdown target

struct MarkdownTargetDetailView: View {
    let targetId: String
    @ObservedObject private var ledger = Ledger.shared

    private var target: MarkdownTarget? {
        ledger.markdownTargets.first(where: { $0.id == targetId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .markdownFolder,
            title: target?.displayName ?? "Markdown folder",
            subtitle: target?.folderPath,
            connectedAt: target?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .markdownFolder(let cfg) = config { return cfg.folderPath == target?.folderPath }
                return false
            }),
            rename: { newName in ledger.renameMarkdownTarget(id: targetId, newName: newName) },
            disconnect: { ledger.removeMarkdownTarget(id: targetId) }
        )
    }
}

// MARK: - Apple Notes target

struct AppleNotesTargetDetailView: View {
    let targetId: String
    @ObservedObject private var ledger = Ledger.shared

    private var target: AppleNotesTarget? {
        ledger.appleNotesTargets.first(where: { $0.id == targetId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .appleNotes,
            title: target?.folderName ?? "Apple Notes",
            subtitle: "iCloud Notes folder",
            connectedAt: target?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .appleNotes(let cfg) = config { return cfg.folderName == target?.folderName }
                return false
            }),
            rename: { newName in ledger.renameAppleNotesTarget(id: targetId, newFolderName: newName) },
            disconnect: { ledger.removeAppleNotesTarget(id: targetId) }
        )
    }
}

// MARK: - reMarkable (still has its own pair-or-list shape)

struct RemarkableDetailView: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var oneTimeCode: String = ""
    @State private var isPairing: Bool = false
    @State private var errorMessage: String?

    private let remarkable = MockRemarkableClient()

    var body: some View {
        if let account = ledger.remarkableAccount {
            // The reMarkable detail when paired is the notebook list; that
            // route is owned by MainView (selection == .remarkable). This
            // branch is a no-op fallback so the view stays valid in previews.
            VStack {
                Text("reMarkable connected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(account.userIdentifier)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
        } else {
            pairForm
                .background(theme.background)
        }
    }

    private var pairForm: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(theme.primary)
                Text("Pair your reMarkable")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Sign in at my.remarkable.com, open the Connect section, and generate an 8-character one-time code.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            CodeBoxField(value: $oneTimeCode, length: 8)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.destructive)
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.destructive)
                }
            }

            AppPrimaryButton(
                title: isPairing ? "Pairing…" : "Pair device",
                systemImage: "qrcode.viewfinder",
                isDisabled: oneTimeCode.count != 8 || isPairing
            ) {
                Task { await pair() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func pair() async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let account = try await remarkable.pairDevice(oneTimeCode: oneTimeCode)
            ledger.setRemarkableAccount(account)
            let notebooks = try await remarkable.listNotebooks()
            ledger.setNotebooks(notebooks)
            oneTimeCode = ""
        } catch {
            errorMessage = Formatters.userMessage(for: error)
        }
    }
}

// MARK: - Shared scaffold (stats title bar + active syncs)

private enum DestinationAuthorization {
    case none
    case keychainToken(title: String, description: String, keychainKey: KeychainStore.Key)
}

private struct DestinationDetailScaffold: View {
    let kind: DestinationKind
    let title: String
    var subtitle: String?
    let connectedAt: Date?
    let activeBindings: [(SyncRule, DestinationBinding)]
    var authorization: DestinationAuthorization = .none
    /// Called when the user submits a rename via the header drawer.
    var rename: ((String) -> Void)? = nil
    let disconnect: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHeaderDrawerOpen = false
    @State private var renameValue: String = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if isHeaderDrawerOpen {
                Divider().background(theme.divider)
                headerDrawer
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(alignment: .center, spacing: 14) {
            DestinationIcon(kind: kind, size: 36)

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
                .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rename == nil)
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

    private var activeSyncsCard: some View {
        AppCard("Active syncs") {
            if activeBindings.isEmpty {
                emptyActiveSyncs
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(activeBindings.enumerated()), id: \.offset) { _, pair in
                        ActiveSyncRow(rule: pair.0, binding: pair.1)
                    }
                }
            }
        }
    }

    private var emptyActiveSyncs: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.tertiary)
            Text("No syncs use this destination yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
            Text("Pick a reMarkable notebook and add this destination from the slider.")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
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

// MARK: - Row

private struct ActiveSyncRow: View {
    let rule: SyncRule
    let binding: DestinationBinding

    @Environment(\.theme) private var theme

    var body: some View {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.cardInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
        )
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

private struct TokenField: View {
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
