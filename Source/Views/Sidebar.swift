//
//  Sidebar.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct Sidebar: View {
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var coordinator: SyncCoordinator
    @Environment(\.theme) private var theme
    @Binding var selection: MainSelection
    var onOpenSettings: () -> Void
    var onOpenLog: () -> Void
    @State private var showAddDestination = false

    init(coordinator: SyncCoordinator,
         selection: Binding<MainSelection>,
         onOpenSettings: @escaping () -> Void,
         onOpenLog: @escaping () -> Void) {
        self.coordinator = coordinator
        self._selection = selection
        self.onOpenSettings = onOpenSettings
        self.onOpenLog = onOpenLog
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            ScrollView {
                VStack(spacing: 14) {
                    sourceSection
                    destinationsSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(theme.surface)
        .overlay(
            Rectangle().fill(theme.divider).frame(width: 1),
            alignment: .trailing
        )
        .sheet(isPresented: $showAddDestination) {
            AddDestinationSheet(isPresented: $showAddDestination)
        }
    }

    // MARK: Header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            BrandMark()
            Text("Sync Bar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Source")
            AccountRow(
                title: "reMarkable",
                subtitle: ledger.remarkableAccount == nil ? "Not connected" : "",
                icon: .asset("Remarkable"),
                isSelected: selection == .remarkable
            )
            .onTapGesture { selection = .remarkable }
        }
    }

    // MARK: Destinations

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Destinations")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.tertiary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { showAddDestination = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .help("Add a destination")
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if isEmptyOfDestinations {
                Text("Add a destination to start syncing")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 14)
            }

            ForEach(ledger.notionWorkspaces) { workspace in
                AccountRow(
                    title: workspace.workspaceName,
                    subtitle: "Notion",
                    icon: .destination(.notion),
                    isSelected: selection == .notionWorkspace(workspace.id)
                )
                .onTapGesture { selection = .notionWorkspace(workspace.id) }
            }
            ForEach(ledger.linearAccounts) { account in
                AccountRow(
                    title: account.name,
                    subtitle: "Linear · \(account.organizationName)",
                    icon: .destination(.linear),
                    isSelected: selection == .linearAccount(account.id)
                )
                .onTapGesture { selection = .linearAccount(account.id) }
            }
            ForEach(ledger.googleAccounts) { account in
                AccountRow(
                    title: account.displayName,
                    subtitle: "Google Docs",
                    icon: .destination(.googleDocs),
                    isSelected: selection == .googleAccount(account.id)
                )
                .onTapGesture { selection = .googleAccount(account.id) }
            }
            ForEach(ledger.markdownTargets) { target in
                AccountRow(
                    title: target.displayName,
                    subtitle: target.folderPath.isEmpty ? "Local files" : (target.folderPath as NSString).abbreviatingWithTildeInPath,
                    icon: .destination(.markdownFolder),
                    isSelected: selection == .markdownTarget(target.id)
                )
                .onTapGesture { selection = .markdownTarget(target.id) }
            }
            ForEach(ledger.appleNotesTargets) { target in
                AccountRow(
                    title: "Apple Notes",
                    subtitle: "iCloud Notes",
                    icon: .destination(.appleNotes),
                    isSelected: selection == .appleNotesTarget(target.id)
                )
                .onTapGesture { selection = .appleNotesTarget(target.id) }
            }
        }
    }

    private var isEmptyOfDestinations: Bool {
        ledger.notionWorkspaces.isEmpty
        && ledger.linearAccounts.isEmpty
        && ledger.googleAccounts.isEmpty
        && ledger.markdownTargets.isEmpty
        && ledger.appleNotesTargets.isEmpty
    }


    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.tertiary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: Footer status bar

    /// Compact bar that mirrors the popover header: a "Last synced …" status
    /// label on the left, a logs button, then the gear. Replaces the older
    /// big Onboarding button.
    private var footer: some View {
        HStack(spacing: 6) {
            statusLabel

            Spacer(minLength: 6)

            footerButton(systemName: "list.bullet.rectangle",
                         help: "Open sync log") {
                onOpenLog()
            }

            footerButton(systemName: "gearshape", help: "Settings (⌘,)") {
                onOpenSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .overlay(
            Rectangle().fill(theme.divider).frame(height: 1),
            alignment: .top
        )
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDot)
                .frame(width: 6, height: 6)
                .shadow(color: statusDot.opacity(0.5), radius: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(statusPrimary)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.foregroundSoft)
                Text(statusSecondary)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiary)
            }
        }
    }

    /// The most recent successful-or-failed sync time across all bindings.
    /// Read from the persisted rules so it survives relaunch (the coordinator's
    /// in-memory lastTickAt resets to nil on launch).
    private var lastSyncDate: Date? {
        ledger.rules.flatMap(\.destinations).compactMap(\.lastRunAt).max()
    }

    private var hasRemarkable: Bool { ledger.remarkableAccount != nil }

    private var hasSyncIssues: Bool {
        ledger.rules.flatMap(\.destinations).contains { $0.lastRunStatus == .error }
    }

    private var statusDot: Color {
        if coordinator.isSyncing { return theme.primary }
        if !hasRemarkable { return theme.destructive }
        if hasSyncIssues { return theme.warning }
        return theme.success
    }

    private var statusPrimary: String {
        if !hasRemarkable { return "Not connected" }
        if hasSyncIssues { return "Issues with reMarkable" }
        return "Connected to reMarkable"
    }

    private var statusSecondary: String {
        if coordinator.isSyncing { return "Syncing now…" }
        if AppSettings.shared.pauseSyncing { return "Syncing paused" }
        guard let last = lastSyncDate else { return "Last sync: never" }
        return "Last sync: \(Formatters.relativeLabel(for: last))"
    }

    private func footerButton(systemName: String,
                              help: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(theme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .strokeBorder(theme.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Rows (reused from prior version)

/// Visual variant for the icon slot on `AccountRow`. Sources (reMarkable)
/// use SF symbols; destinations use the bundled brand asset.
enum AccountRowIcon {
    case systemSymbol(String, accent: Bool)
    case destination(DestinationKind)
    /// A bundled brand image (e.g. the reMarkable logo) rendered in a rounded tile.
    case asset(String)
}

private struct AccountRow: View {
    let title: String
    let subtitle: String
    let icon: AccountRowIcon
    let isSelected: Bool

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.foreground : theme.foregroundSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isSelected ? theme.primary.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(theme.primary.opacity(0.10))
        } else if isHovered {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.white.opacity(0.02))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .systemSymbol(let name, let accent):
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.cardElevated)
                Image(systemName: name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent ? theme.primary : theme.tertiary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.borderStrong, lineWidth: 1)
            )
        case .destination(let kind):
            DestinationIcon(kind: kind, size: 22)
        case .asset(let name):
            Image(name)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.borderStrong, lineWidth: 1)
                )
        }
    }
}

