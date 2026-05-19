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
    @Environment(\.theme) private var theme

    private var workspace: NotionWorkspace? {
        ledger.notionWorkspaces.first(where: { $0.id == workspaceId })
    }

    var body: some View {
        DestinationDetailScaffold(
            iconName: DestinationKind.notion.systemImage,
            title: workspace?.workspaceName ?? "Workspace",
            subtitle: "Notion workspace",
            disconnect: { ledger.removeNotionWorkspace(id: workspaceId) }
        ) {
            AppCard("Workspace") {
                VStack(spacing: 0) {
                    AppSettingRow("Name", description: "Display name across SyncNerds.") {
                        Text(workspace?.workspaceName ?? "—")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.foreground)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Connected", description: nil) {
                        Text(workspace.map { Formatters.logRowLabel(for: $0.connectedAt) } ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Bindings", description: "Rules currently writing to this workspace.") {
                        Text("\(bindingsCount)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.foreground)
                    }
                }
            }
        }
    }

    private var bindingsCount: Int {
        ledger.rules.flatMap(\.destinations).filter {
            if case .notion(let cfg) = $0.configuration { return cfg.workspaceId == workspaceId }
            return false
        }.count
    }
}

// MARK: - Linear account

struct LinearAccountDetailView: View {
    let accountId: String
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    private var account: LinearAccount? {
        ledger.linearAccounts.first(where: { $0.id == accountId })
    }

    var body: some View {
        DestinationDetailScaffold(
            iconName: DestinationKind.linear.systemImage,
            title: account?.name ?? "Linear team",
            subtitle: account.map { "Linear · \($0.organizationName)" } ?? "Linear",
            disconnect: { ledger.removeLinearAccount(id: accountId) }
        ) {
            AppCard("Team") {
                VStack(spacing: 0) {
                    AppSettingRow("Team", description: nil) {
                        Text(account?.name ?? "—")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.foreground)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Organization", description: nil) {
                        Text(account?.organizationName ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Connected", description: nil) {
                        Text(account.map { Formatters.logRowLabel(for: $0.connectedAt) } ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                }
            }
            AppCard("Authorization") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SyncNerds creates issues via Linear's GraphQL API. Paste a personal access token from linear.app/settings/account/security to enable real writes.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                    TokenField(
                        title: "Linear access token",
                        keychainKey: .linearAccessToken
                    )
                }
            }
        }
    }
}

// MARK: - Google Docs account

struct GoogleAccountDetailView: View {
    let accountId: String
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    private var account: GoogleAccount? {
        ledger.googleAccounts.first(where: { $0.id == accountId })
    }

    var body: some View {
        DestinationDetailScaffold(
            iconName: DestinationKind.googleDocs.systemImage,
            title: account?.displayName ?? "Google account",
            subtitle: "Google Docs",
            disconnect: { ledger.removeGoogleAccount(id: accountId) }
        ) {
            AppCard("Account") {
                VStack(spacing: 0) {
                    AppSettingRow("Email", description: nil) {
                        Text(account?.id ?? accountId)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.foreground)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Connected", description: nil) {
                        Text(account.map { Formatters.logRowLabel(for: $0.connectedAt) } ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                }
            }
            AppCard("Authorization") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SyncNerds writes via the Google Docs + Drive APIs. Add an OAuth access token below to enable real writes; otherwise a mock returns a synthetic Docs URL.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                    TokenField(
                        title: "Google access token",
                        keychainKey: .googleAccessToken(email: accountId)
                    )
                }
            }
        }
    }
}

// MARK: - Markdown target

struct MarkdownTargetDetailView: View {
    let targetId: String
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    private var target: MarkdownTarget? {
        ledger.markdownTargets.first(where: { $0.id == targetId })
    }

    var body: some View {
        DestinationDetailScaffold(
            iconName: DestinationKind.markdownFolder.systemImage,
            title: target?.displayName ?? "Markdown folder",
            subtitle: "Local Markdown files",
            disconnect: { ledger.removeMarkdownTarget(id: targetId) }
        ) {
            AppCard("Folder") {
                VStack(spacing: 0) {
                    AppSettingRow("Path", description: "SyncNerds writes one .md file per synced page.") {
                        Text(target?.folderPath ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Connected", description: nil) {
                        Text(target.map { Formatters.logRowLabel(for: $0.connectedAt) } ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                }
            }
        }
    }
}

// MARK: - Apple Notes target

struct AppleNotesTargetDetailView: View {
    let targetId: String
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    private var target: AppleNotesTarget? {
        ledger.appleNotesTargets.first(where: { $0.id == targetId })
    }

    var body: some View {
        DestinationDetailScaffold(
            iconName: DestinationKind.appleNotes.systemImage,
            title: target?.folderName ?? "Apple Notes",
            subtitle: "Apple Notes folder",
            disconnect: { ledger.removeAppleNotesTarget(id: targetId) }
        ) {
            AppCard("Folder") {
                VStack(spacing: 0) {
                    AppSettingRow("Folder", description: "SyncNerds creates this folder in iCloud Notes if needed.") {
                        Text(target?.folderName ?? "—")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.foreground)
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Connected", description: nil) {
                        Text(target.map { Formatters.logRowLabel(for: $0.connectedAt) } ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                }
            }
            AppCard("Required permission") {
                Text("On first sync, macOS will ask permission for SyncNerds to control Notes via AppleScript. Grant it in System Settings → Privacy & Security → Automation.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
        }
    }
}

// MARK: - reMarkable detail (re-used)

struct RemarkableDetailView: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var oneTimeCode: String = ""
    @State private var isPairing: Bool = false
    @State private var errorMessage: String?

    private let remarkable = MockRemarkableClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let account = ledger.remarkableAccount {
                    AppCard("Device") {
                        VStack(spacing: 0) {
                            AppSettingRow("Identifier", description: "Opaque value from the reMarkable cloud.") {
                                Text(account.userIdentifier)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(theme.foreground)
                            }
                            AppRowDivider().padding(.vertical, 10)
                            AppSettingRow("Paired", description: nil) {
                                Text(Formatters.logRowLabel(for: account.pairedAt))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.muted)
                            }
                            AppRowDivider().padding(.vertical, 10)
                            AppSettingRow("Last sync", description: nil) {
                                Text(account.lastSyncedAt.map(Formatters.logRowLabel(for:)) ?? "Never")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.muted)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        AppSecondaryButton(title: "Disconnect device", systemImage: "minus.circle", tint: .destructive) {
                            ledger.setRemarkableAccount(nil)
                        }
                    }
                } else {
                    pairForm
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .background(theme.background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card)
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 48, height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.borderStrong, lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("reMarkable")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(ledger.remarkableAccount == nil ? "Not paired" : "Connected")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
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

// MARK: - Shared scaffold

private struct DestinationDetailScaffold<Content: View>: View {
    let iconName: String
    let title: String
    let subtitle: String
    let disconnect: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card)
                        Image(systemName: iconName)
                            .font(.system(size: 22))
                            .foregroundStyle(theme.primary)
                    }
                    .frame(width: 48, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.borderStrong, lineWidth: 1)
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                    Spacer()
                }
                content()
                HStack {
                    Spacer()
                    AppSecondaryButton(title: "Disconnect", systemImage: "minus.circle", tint: .destructive) {
                        disconnect()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .background(theme.background)
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
