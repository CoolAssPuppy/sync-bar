//
//  AddSourceSheet.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Modal to add a Source — the mirror of AddDestinationSheet. Pick reMarkable
/// (pair with a one-time code), Safari (grant Full Disk Access to read
/// bookmarks), or Reminders (grant access for a two-way sync with Notion). A
/// source must be added before it appears in a sync editor.
struct AddSourceSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    /// What's addable here. Reminders is offered as a source even though it isn't
    /// a one-way SourceClient — it's the Reminders half of a two-way TaskSync.
    private enum AddableSource: Hashable, Identifiable, CaseIterable {
        case remarkable, safari, x, reminders
        var id: String { "\(self)" }
        var label: String {
            switch self {
            case .remarkable: return SourceKind.remarkable.label
            case .safari:     return SourceKind.safari.label
            case .x:          return SourceKind.x.label
            case .reminders:  return "Reminders"
            }
        }
        var subtitle: String {
            switch self {
            case .remarkable: return SourceKind.remarkable.subtitle
            case .safari:     return SourceKind.safari.subtitle
            case .x:          return SourceKind.x.subtitle
            case .reminders:  return "Two-way sync with Notion"
            }
        }
    }

    @State private var selected: AddableSource = .remarkable
    @State private var showingPair = false
    @State private var safariHasAccess = false
    /// The X content streams the user has opted into; only their scopes are
    /// requested at connect time. Defaults to all three.
    @State private var xStreams: Set<XStream> = Set(XStream.allCases)
    @State private var xConnecting = false
    @State private var xError: String?

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
        .frame(width: 520, height: 480)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear { safariHasAccess = FullDiskAccessProbe.hasAccess() }
        .sheet(isPresented: $showingPair) {
            RemarkablePairPanel(title: "Pair your reMarkable",
                                onClose: { showingPair = false },
                                onPaired: { showingPair = false; isPresented = false })
        }
    }

    private func header(theme: ThemePalette) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a Source").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.foreground)
                Text("Pick where Sync Bar pulls information from.").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.foreground)
                    .frame(width: 28, height: 28).background(Circle().fill(theme.card))
                    .overlay(Circle().strokeBorder(theme.borderStrong, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func kindPicker(theme: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source Type")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.tertiary).textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AddableSource.allCases) { source in
                    SourceTile(icon: tileIcon(for: source), label: source.label,
                               subtitle: source.subtitle, isSelected: selected == source) {
                        selected = source
                    }
                }
            }
        }
    }

    @ViewBuilder private func tileIcon(for source: AddableSource) -> some View {
        switch source {
        case .remarkable: SourceIcon(kind: .remarkable, size: 28)
        case .safari:     SourceIcon(kind: .safari, size: 28)
        case .x:          SourceIcon(kind: .x, size: 28)
        case .reminders:
            Image("Reminders").resizable().interpolation(.high).scaledToFit().frame(width: 28, height: 28)
        }
    }

    @ViewBuilder private func detailsCard(theme: ThemePalette) -> some View {
        switch selected {
        case .remarkable:
            Text("Pair your reMarkable with an 8-character one-time code from my.remarkable.com → Connect. Your tablet folders become sources you can sync.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .safari:
            VStack(alignment: .leading, spacing: 8) {
                Text("Read your Safari bookmarks (Favorites and Bookmarks Menu). Sync Bar needs Full Disk Access to read them — you'll grant it in System Settings, then relaunch the app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !safariHasAccess {
                    Text("Full Disk Access isn't granted yet — connecting will open System Settings.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
            }
        case .x:
            xDetails(theme: theme)
        case .reminders:
            Text("Keep an Apple Reminders list and a Notion database in sync, both ways. Sync Bar will ask for Reminders access; then create a two-way sync from the Syncs screen.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func xDetails(theme: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync your X content into any destination. Choose which content types to pull — each becomes its own sync stream with its own history. Sync Bar requests only the access the types you pick need.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(XStream.allCases) { stream in
                    streamToggle(stream, theme: theme)
                }
            }
            if !AuthSecrets.isXConfigured {
                Text("X isn't configured yet — add its OAuth client id (see the README) and rebuild to connect.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
            if let xError {
                Text(xError).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.destructive)
            }
        }
    }

    private func streamToggle(_ stream: XStream, theme: ThemePalette) -> some View {
        let isOn = xStreams.contains(stream)
        return Button(action: {
            if isOn { xStreams.remove(stream) } else { xStreams.insert(stream) }
        }) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(isOn ? theme.primary : theme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(stream.label).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.foreground)
                    Text(stream.subtitle).font(.system(size: 10)).foregroundStyle(theme.muted)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func footer(theme: ThemePalette) -> some View {
        HStack {
            Spacer()
            AppSecondaryButton(title: "Cancel") { isPresented = false }
            AppPrimaryButton(title: primaryTitle, systemImage: primaryIcon, isDisabled: primaryDisabled) { primaryAction() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14).background(theme.surface)
    }

    private var primaryTitle: LocalizedStringKey {
        switch selected {
        case .remarkable: return "Pair reMarkable"
        case .safari:     return "Connect Safari"
        case .x:          return xConnecting ? "Connecting…" : "Connect X"
        case .reminders:  return "Connect Reminders"
        }
    }

    private var primaryIcon: String {
        switch selected {
        case .remarkable: return "qrcode.viewfinder"
        case .safari:     return "externaldrive"
        case .x:          return "at"
        case .reminders:  return "checklist"
        }
    }

    private func primaryAction() {
        switch selected {
        case .remarkable:
            showingPair = true
        case .x:
            connectX()
        case .safari:
            ledger.setSafariConnected(true)
            safariHasAccess = FullDiskAccessProbe.hasAccess()
            if !safariHasAccess { FullDiskAccessProbe.openSystemSettings() }
            isPresented = false
        case .reminders:
            // Request access (shows the system prompt). Mark connected regardless
            // so the user can manage it in Connections; the editor degrades to an
            // empty list with a hint if access was declined.
            Task {
                _ = await EventKitRemindersClient().requestAccess()
                await MainActor.run {
                    ledger.setRemindersConnected(true)
                    isPresented = false
                }
            }
        }
    }

    /// Whether the primary action is unavailable for the current selection.
    private var primaryDisabled: Bool {
        switch selected {
        case .x: return xConnecting || !AuthSecrets.isXConfigured || xStreams.isEmpty
        default: return false
        }
    }

    /// Runs the X OAuth flow for the chosen streams, stores the account, closes.
    private func connectX() {
        guard !xConnecting, !xStreams.isEmpty else { return }
        xConnecting = true
        xError = nil
        let streams = XStream.allCases.filter { xStreams.contains($0) }
        Task {
            do {
                let account = try await XAuthService.shared.connect(streams: streams)
                await MainActor.run {
                    ledger.upsertXAccount(account)
                    xConnecting = false
                    isPresented = false
                }
            } catch OAuthError.userCancelled {
                await MainActor.run { xConnecting = false }
            } catch {
                let message = Formatters.userMessage(for: error)
                await MainActor.run { xConnecting = false; xError = message }
            }
        }
    }
}

/// A selectable source tile (brand or symbol icon + label + subtitle).
private struct SourceTile<Icon: View>: View {
    let icon: Icon
    let label: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    icon
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary).font(.system(size: 13))
                    }
                }
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.foreground)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(isSelected ? theme.primary.opacity(0.08) : theme.card))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(isSelected ? theme.primary.opacity(0.35) : theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
