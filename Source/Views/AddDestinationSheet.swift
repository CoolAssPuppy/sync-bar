//
//  AddDestinationSheet.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

/// Modal sheet shown from the sidebar's "+ Add destination" button. Lets
/// the user pick a destination kind and walks them through the minimal
/// setup needed for that kind. Notion/Linear/Google use mocks until real
/// OAuth tokens land; Apple Notes and Markdown work end-to-end here.
struct AddDestinationSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    @State private var selectedKind: DestinationKind = .notion
    @State private var markdownPath: String = ""
    @State private var appleNotesFolder: String = "SyncNerds"
    @State private var googleEmail: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?

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
    }

    // MARK: Header

    private func header(theme: ThemePalette) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a destination")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Pick a place to send your transcribed notes.")
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
            Text("Destination type")
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
        }
    }

    private var notionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Notion with OAuth. SyncNerds opens Notion in your browser, you pick the pages and databases to share, and the workspace is added here.")
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
            Text("Connect Linear with OAuth. SyncNerds opens Linear in a secure window, then adds every team you can access as a destination.")
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
            Text("Adds a Google account row. Real Docs writes require an OAuth token in Settings; until then a mock returns a Docs URL.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            AppSettingRow("Account email", description: nil) {
                TextField("you@example.com", text: $googleEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
    }

    private var appleNotesFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Notes uses your local iCloud Notes account. SyncNerds creates the folder if it doesn't exist.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            AppSettingRow("Folder name", description: nil) {
                TextField("SyncNerds, Notes, …", text: $appleNotesFolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    private var markdownFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Writes one Markdown file per synced page into a folder you choose. Works with Obsidian, Bear, iA Writer, anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            AppSettingRow("Folder", description: nil) {
                HStack(spacing: 6) {
                    Text(markdownPath.isEmpty ? "Not chosen" : markdownPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                    AppSecondaryButton(title: "Choose…", systemImage: "folder") {
                        chooseFolder()
                    }
                }
            }
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
        selectedKind == .linear || selectedKind == .notion
    }

    private var primaryTitle: LocalizedStringKey {
        switch selectedKind {
        case .linear: return isConnecting ? "Connecting…" : "Connect Linear"
        case .notion: return isConnecting ? "Connecting…" : "Connect Notion"
        default:      return "Add destination"
        }
    }

    private var primaryIcon: String {
        isOAuthKind ? "link" : "plus"
    }

    private func primaryAction() {
        switch selectedKind {
        case .linear: Task { await connectLinear() }
        case .notion: Task { await connectNotion() }
        default:      submit()
        }
    }

    private var canSubmit: Bool {
        switch selectedKind {
        case .notion:         return AuthSecrets.isNotionConfigured && !isConnecting
        case .linear:         return AuthSecrets.isLinearConfigured && !isConnecting
        case .googleDocs:     return googleEmail.contains("@")
        case .appleNotes:     return !appleNotesFolder.trimmingCharacters(in: .whitespaces).isEmpty
        case .markdownFolder: return !markdownPath.isEmpty
        }
    }

    private func connectNotion() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let workspace = try await NotionAuthService.shared.connect()
            ledger.upsertNotionWorkspace(workspace)
            isPresented = false
        } catch OAuthError.userCancelled {
            // User backed out; leave the sheet open.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func connectLinear() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let accounts = try await LinearAuthService.shared.connect()
            for account in accounts { ledger.upsertLinearAccount(account) }
            isPresented = false
        } catch OAuthError.userCancelled {
            // User backed out of the web flow; leave the sheet open, no error.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit() {
        switch selectedKind {
        case .notion, .linear:
            break  // handled by connect{Notion,Linear}() via primaryAction()
        case .googleDocs:
            ledger.upsertGoogleAccount(GoogleAccount(
                id: googleEmail.lowercased(),
                displayName: googleEmail,
                connectedAt: Date()
            ))
            isPresented = false
        case .appleNotes:
            ledger.upsertAppleNotesTarget(AppleNotesTarget(
                id: "an-" + UUID().uuidString.prefix(8).lowercased(),
                folderName: appleNotesFolder,
                connectedAt: Date()
            ))
            isPresented = false
        case .markdownFolder:
            let url = URL(fileURLWithPath: markdownPath, isDirectory: true)
            ledger.upsertMarkdownTarget(MarkdownTarget(
                id: "md-" + UUID().uuidString.prefix(8).lowercased(),
                displayName: url.lastPathComponent,
                folderPath: markdownPath,
                connectedAt: Date()
            ))
            isPresented = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Pick a folder for Markdown notes"
        if panel.runModal() == .OK, let url = panel.url {
            markdownPath = url.path
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
