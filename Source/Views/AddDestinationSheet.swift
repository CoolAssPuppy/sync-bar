//
//  AddDestinationSheet.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Modal sheet shown from the sidebar's "+ Add destination" button. Lets
/// the user pick a destination kind and walks them through the minimal
/// setup needed for that kind. Notion/Linear/Google use mocks until real
/// OAuth tokens land; Apple Notes and Markdown work end-to-end here.
struct AddDestinationSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    @State private var selectedKind: DestinationKind = .notion
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    /// Teams returned by a Linear connect, awaiting the user's pick. Non-nil shows
    /// the team picker instead of adding every team.
    @State private var linearTeamChoices: LinearTeamChoices?

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            header(theme: theme)
            Divider().background(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    kindPicker(theme: theme)
                    detailsCard(theme: theme)
                }
                .padding(20)
            }
            Divider().background(theme.divider)
            footer(theme: theme)
        }
        .frame(width: 520, height: 560)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .sheet(item: $linearTeamChoices) { choices in
            LinearTeamPickerSheet(
                teams: choices.teams,
                preselected: Set(ledger.linearAccounts.map(\.id)),
                onConfirm: { selectedIds in
                    ledger.applyLinearTeamSelection(available: choices.teams, selectedIds: selectedIds)
                    Telemetry.capture("destination.connected", properties: ["provider": "linear"])
                    linearTeamChoices = nil
                    isPresented = false
                },
                onCancel: { linearTeamChoices = nil }
            )
        }
    }

    // MARK: Header

    private func header(theme: ThemePalette) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a Destination")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Pick where Sync Bar sends information to")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            Button(action: { isPresented = false }) {
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

    // MARK: Kind picker

    private func kindPicker(theme: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination Type")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.tertiary)
                .textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(DestinationKind.allCases) { kind in
                    KindTile(kind: kind, isSelected: selectedKind == kind) {
                        selectedKind = kind
                    }
                }
            }
        }
    }

    // MARK: Details card

    @ViewBuilder
    private func detailsCard(theme: ThemePalette) -> some View {
        switch selectedKind {
        case .notion:         notionFields
        case .linear:         linearFields
        case .googleDocs:     googleFields
        case .appleNotes:     appleNotesFields
        case .markdownFolder: markdownFields
        case .chrome:         chromeFields
        }
    }

    private var chromeFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("""
                Writes bookmarks into your Google Chrome profile. You choose which Chrome folder \
                when you set up each sync. Chrome must be quit for the change to apply — otherwise \
                it syncs the next time Chrome is closed.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var notionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Notion with OAuth. Sync Bar opens Notion in your browser, you pick the pages and databases to share, and the workspace is added here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !AuthSecrets.isNotionConfigured {
                oauthNotConfiguredHint(provider: "Notion")
            }
            if let errorMessage {
                oauthErrorRow(errorMessage)
            }
        }
    }

    private var linearFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Linear with OAuth. Sync Bar opens Linear in a secure window, then adds every team you can access as a destination.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !AuthSecrets.isLinearConfigured {
                oauthNotConfiguredHint(provider: "Linear")
            }
            if let errorMessage {
                oauthErrorRow(errorMessage)
            }
        }
    }

    private func oauthNotConfiguredHint(provider: String) -> some View {
        Text("\(provider) OAuth isn't configured in this build. Add its client credentials (see the README) and rebuild.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
    }

    private func oauthErrorRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.red)
    }

    private var googleFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Google with OAuth. Sync Bar opens Google in your browser, you grant access to Docs and Drive, and the account is added here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Google Docs integration is subject to Google's absurd CASA certification. This will take time and money.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
            if !AuthSecrets.isGoogleConfigured {
                oauthNotConfiguredHint(provider: "Google")
            }
            if let errorMessage {
                oauthErrorRow(errorMessage)
            }
        }
    }

    private var appleNotesFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Notes uses your local iCloud Notes account. You'll choose which folder to use when you set up a sync for a reMarkable folder.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var markdownFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("""
                Writes one Markdown file per synced page. Works with Obsidian, Bear, iA Writer, \
                anything. You choose the destination folder and file-name template when you set \
                up each sync, so one Markdown connection can feed different folders.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private func footer(theme: ThemePalette) -> some View {
        HStack {
            Spacer()
            AppSecondaryButton(title: "Cancel") { isPresented = false }
            AppPrimaryButton(title: primaryTitle, systemImage: primaryIcon, isDisabled: !canSubmit) {
                primaryAction()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.surface)
    }

    private var isOAuthKind: Bool {
        selectedKind == .linear || selectedKind == .notion || selectedKind == .googleDocs
    }

    private var primaryTitle: LocalizedStringKey {
        switch selectedKind {
        case .linear:         return isConnecting ? "Connecting…" : "Connect Linear"
        case .notion:         return isConnecting ? "Connecting…" : "Connect Notion"
        case .googleDocs:     return isConnecting ? "Connecting…" : "Connect Google"
        case .appleNotes:     return "Connect Notes"
        case .markdownFolder: return "Connect Markdown"
        case .chrome:         return "Connect Chrome"
        }
    }

    private var primaryIcon: String {
        isOAuthKind ? "link" : "plus"
    }

    private func primaryAction() {
        switch selectedKind {
        case .linear:     Task { await connectLinear() }
        case .notion:     Task { await connectNotion() }
        case .googleDocs: Task { await connectGoogle() }
        default:          submit()
        }
    }

    private var canSubmit: Bool {
        switch selectedKind {
        case .notion:         return AuthSecrets.isNotionConfigured && !isConnecting
        case .linear:         return AuthSecrets.isLinearConfigured && !isConnecting
        case .googleDocs:     return AuthSecrets.isGoogleConfigured && !isConnecting
        case .appleNotes:     return true
        case .markdownFolder: return true
        case .chrome:         return true
        }
    }

    private func connectGoogle() async {
        await connect(.googleDocs) {
            ledger.upsertGoogleAccount(try await GoogleAuthService.shared.connect())
        }
    }

    private func connectNotion() async {
        await connect(.notion) {
            ledger.upsertNotionWorkspace(try await NotionAuthService.shared.connect())
        }
    }

    private func connectLinear() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            // Fetch the teams, then let the user choose, rather than adding all.
            linearTeamChoices = LinearTeamChoices(teams: try await LinearAuthService.shared.connect())
        } catch OAuthError.userCancelled {
            // User backed out of the web flow; leave the sheet open, no error.
        } catch {
            Telemetry.capture("destination.connect_failed", properties: ["provider": "linear"])
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Shared OAuth connect flow: flips the connecting flag, records analytics,
    /// dismisses on success, and leaves the sheet open with no error when the
    /// user cancels the web flow.
    private func connect(_ kind: DestinationKind, perform: () async throws -> Void) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await perform()
            Telemetry.capture("destination.connected", properties: ["provider": kind.rawValue])
            isPresented = false
        } catch OAuthError.userCancelled {
            // User backed out of the web flow; leave the sheet open, no error.
        } catch {
            Telemetry.capture("destination.connect_failed", properties: ["provider": kind.rawValue])
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit() {
        switch selectedKind {
        case .notion, .linear, .googleDocs:
            break  // handled by connect{Notion,Linear,Google}() via primaryAction()
        case .appleNotes:
            // The folder is chosen per reMarkable-folder binding, so the target
            // is just a marker that Apple Notes is available. "Sync Bar" seeds
            // the binding's default folder. One marker is enough.
            if ledger.appleNotesTargets.isEmpty {
                ledger.upsertAppleNotesTarget(AppleNotesTarget(
                    id: "an-" + UUID().uuidString.prefix(8).lowercased(),
                    folderName: "Sync Bar",
                    connectedAt: Date()
                ))
                Telemetry.capture("destination.connected", properties: ["provider": selectedKind.rawValue])
            }
            isPresented = false
        case .markdownFolder:
            // One generic Markdown connection. The destination folder and
            // file-name template are chosen per sync (in the sync editor), so
            // this is just a marker that Markdown is available - the same model
            // as Apple Notes. One marker is enough.
            if ledger.markdownTargets.isEmpty {
                ledger.upsertMarkdownTarget(MarkdownTarget(
                    id: "md-" + UUID().uuidString.prefix(8).lowercased(),
                    displayName: "Markdown",
                    folderPath: "",
                    connectedAt: Date()
                ))
                Telemetry.capture("destination.connected", properties: ["provider": selectedKind.rawValue])
            }
            isPresented = false
        case .chrome:
            // A marker that Chrome is available; the profile + target folder are
            // chosen per sync (in the sync editor), like Markdown and Apple Notes.
            if ledger.chromeTargets.isEmpty {
                ledger.upsertChromeTarget(ChromeTarget(
                    id: "chrome-" + UUID().uuidString.prefix(8).lowercased(),
                    displayName: "Chrome",
                    profileDirName: "Default",
                    connectedAt: Date()
                ))
                Telemetry.capture("destination.connected", properties: ["provider": selectedKind.rawValue])
            }
            isPresented = false
        }
    }
}

// MARK: - Kind tile

private struct KindTile: View {
    let kind: DestinationKind
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DestinationIcon(kind: kind, size: 28)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.primary)
                            .font(.system(size: 13))
                    }
                }
                Text(kind.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(kind.sidebarSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(isSelected ? theme.primary.opacity(0.08) : theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(isSelected ? theme.primary.opacity(0.35) : theme.border, lineWidth: 1)
            )
            .scaleEffect(isHovered && !isSelected ? 1.01 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
