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
    @State private var inputLabel: String = ""
    @State private var markdownPath: String = ""
    @State private var appleNotesFolder: String = "SyncNerds"
    @State private var linearTeamName: String = ""
    @State private var linearOrgName: String = ""
    @State private var googleEmail: String = ""
    @State private var statusMessage: String?

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            header(theme: theme)
            Divider().background(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    kindPicker(theme: theme)
                    detailsCard(theme: theme)
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
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
                        statusMessage = nil
                    }
                }
            }
        }
    }

    // MARK: Details card

    @ViewBuilder
    private func detailsCard(theme: ThemePalette) -> some View {
        AppCard(LocalizedStringKey("Setup for \(selectedKind.label)")) {
            switch selectedKind {
            case .notion:         notionFields
            case .linear:         linearFields
            case .googleDocs:     googleFields
            case .appleNotes:     appleNotesFields
            case .markdownFolder: markdownFields
            }
        }
    }

    private var notionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SyncNerds will create a mock workspace right now so you can wire up rules. Real Notion OAuth lives in Settings → Accounts when you have credentials.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            AppSettingRow("Workspace label",
                          description: "Just a display name. The mock returns a deterministic Notion workspace id.") {
                TextField("Personal, Work, …", text: $inputLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    private var linearFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connects a Linear team. Without an access token, SyncNerds writes via a mock that returns a synthetic issue identifier.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            AppSettingRow("Team name", description: nil) {
                TextField("Engineering, Growth, …", text: $linearTeamName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            AppSettingRow("Organization", description: nil) {
                TextField("Acme Inc", text: $linearOrgName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
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
            AppPrimaryButton(title: "Add destination", systemImage: "plus", isDisabled: !canSubmit) {
                submit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.surface)
    }

    private var canSubmit: Bool {
        switch selectedKind {
        case .notion:         return !inputLabel.trimmingCharacters(in: .whitespaces).isEmpty
        case .linear:         return !linearTeamName.trimmingCharacters(in: .whitespaces).isEmpty
        case .googleDocs:     return googleEmail.contains("@")
        case .appleNotes:     return !appleNotesFolder.trimmingCharacters(in: .whitespaces).isEmpty
        case .markdownFolder: return !markdownPath.isEmpty
        }
    }

    private func submit() {
        switch selectedKind {
        case .notion:
            Task { @MainActor in
                let workspace = try? await MockNotionClient().connectMockWorkspace(label: inputLabel)
                if let workspace { ledger.upsertNotionWorkspace(workspace) }
                isPresented = false
            }
        case .linear:
            ledger.upsertLinearAccount(LinearAccount(
                id: "team-" + UUID().uuidString.prefix(8).lowercased(),
                name: linearTeamName.trimmingCharacters(in: .whitespaces),
                organizationName: linearOrgName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Personal" : linearOrgName.trimmingCharacters(in: .whitespaces),
                connectedAt: Date()
            ))
            isPresented = false
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
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.cardElevated)
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? theme.primary : theme.foregroundSoft)
                    }
                    .frame(width: 28, height: 28)
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
