//
//  Sidebar.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct Sidebar: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme
    @Binding var selection: MainSelection
    var onOpenSettings: () -> Void
    @State private var showAddDestination = false

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            ScrollView {
                VStack(spacing: 14) {
                    sourceSection
                    destinationsSection
                    navigationSection
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
            VStack(alignment: .leading, spacing: 1) {
                Text("SyncNerds")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        if ledger.remarkableAccount == nil { return "Setup required" }
        let total = ledger.rules.reduce(0) { $0 + $1.destinations.count }
        return total == 0 ? "Add a destination" : "\(total) destination\(total == 1 ? "" : "s")"
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Source")
            AccountRow(
                title: "reMarkable",
                subtitle: ledger.remarkableAccount.map { "Paired \(Formatters.relativeLabel(for: $0.pairedAt))" } ?? "Not connected",
                systemImage: "pencil.tip.crop.circle",
                isSelected: selection == .remarkable,
                isAccent: ledger.remarkableAccount != nil
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
                Button(action: { showAddDestination = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add destination")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.foreground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(theme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(theme.borderStrong)
                    )
                }
                .buttonStyle(.plain)
            }

            ForEach(ledger.notionWorkspaces) { workspace in
                AccountRow(
                    title: workspace.workspaceName,
                    subtitle: "Notion",
                    systemImage: DestinationKind.notion.systemImage,
                    isSelected: selection == .notionWorkspace(workspace.id),
                    isAccent: true
                )
                .onTapGesture { selection = .notionWorkspace(workspace.id) }
            }
            ForEach(ledger.linearAccounts) { account in
                AccountRow(
                    title: account.name,
                    subtitle: "Linear · \(account.organizationName)",
                    systemImage: DestinationKind.linear.systemImage,
                    isSelected: selection == .linearAccount(account.id),
                    isAccent: true
                )
                .onTapGesture { selection = .linearAccount(account.id) }
            }
            ForEach(ledger.googleAccounts) { account in
                AccountRow(
                    title: account.displayName,
                    subtitle: "Google Docs",
                    systemImage: DestinationKind.googleDocs.systemImage,
                    isSelected: selection == .googleAccount(account.id),
                    isAccent: true
                )
                .onTapGesture { selection = .googleAccount(account.id) }
            }
            ForEach(ledger.markdownTargets) { target in
                AccountRow(
                    title: target.displayName,
                    subtitle: "Markdown · \((target.folderPath as NSString).lastPathComponent)",
                    systemImage: DestinationKind.markdownFolder.systemImage,
                    isSelected: selection == .markdownTarget(target.id),
                    isAccent: true
                )
                .onTapGesture { selection = .markdownTarget(target.id) }
            }
            ForEach(ledger.appleNotesTargets) { target in
                AccountRow(
                    title: target.folderName,
                    subtitle: "Apple Notes",
                    systemImage: DestinationKind.appleNotes.systemImage,
                    isSelected: selection == .appleNotesTarget(target.id),
                    isAccent: true
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

    // MARK: Navigation

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("View")
            NavRow(
                title: "Notebooks",
                systemImage: "book.closed",
                isSelected: selection == .notebooks,
                badge: ledger.notebooks.isEmpty ? nil : "\(ledger.notebooks.count)"
            )
            .onTapGesture { selection = .notebooks }

            NavRow(
                title: "Sync log",
                systemImage: "list.bullet.rectangle",
                isSelected: selection == .syncLog,
                badge: ledger.events.isEmpty ? nil : "\(ledger.events.count)"
            )
            .onTapGesture { selection = .syncLog }
        }
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: { NotificationCenter.default.post(name: .openOnboarding, object: nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                    Text("Onboarding")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
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

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .frame(width: 34, height: 32)
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
            .keyboardShortcut(",", modifiers: .command)
            .help(LocalizedStringKey("Settings (⌘,)"))
        }
        .padding(12)
        .overlay(
            Rectangle().fill(theme.divider).frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - Rows (reused from prior version)

private struct AccountRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    let isAccent: Bool

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.cardElevated)
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isAccent ? theme.primary : theme.tertiary)
            }
            .frame(width: 22, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.borderStrong, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.foreground : theme.foregroundSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
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
}

private struct NavRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let badge: String?

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? theme.primary : theme.muted)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.foreground : theme.foregroundSoft)
            Spacer(minLength: 6)
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.cardElevated))
            }
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
}
