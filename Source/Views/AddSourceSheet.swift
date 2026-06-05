//
//  AddSourceSheet.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Modal to add a Source — the mirror of AddDestinationSheet. Pick reMarkable
/// (pair with a one-time code) or Safari (grant Full Disk Access to read
/// bookmarks). A source must be added before it appears in the sync editor.
struct AddSourceSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    @State private var selectedKind: SourceKind = .remarkable
    @State private var showingPair = false
    @State private var safariHasAccess = false

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
                ForEach(SourceKind.allCases) { kind in
                    SourceKindTile(kind: kind, isSelected: selectedKind == kind) { selectedKind = kind }
                }
            }
        }
    }

    @ViewBuilder private func detailsCard(theme: ThemePalette) -> some View {
        switch selectedKind {
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
        }
    }

    private func footer(theme: ThemePalette) -> some View {
        HStack {
            Spacer()
            AppSecondaryButton(title: "Cancel") { isPresented = false }
            AppPrimaryButton(title: primaryTitle, systemImage: primaryIcon, isDisabled: false) { primaryAction() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14).background(theme.surface)
    }

    private var primaryTitle: LocalizedStringKey {
        switch selectedKind {
        case .remarkable: return "Pair reMarkable"
        case .safari:     return "Connect Safari"
        }
    }

    private var primaryIcon: String {
        switch selectedKind {
        case .remarkable: return "qrcode.viewfinder"
        case .safari:     return "externaldrive"
        }
    }

    private func primaryAction() {
        switch selectedKind {
        case .remarkable:
            showingPair = true
        case .safari:
            ledger.setSafariConnected(true)
            safariHasAccess = FullDiskAccessProbe.hasAccess()
            if !safariHasAccess { FullDiskAccessProbe.openSystemSettings() }
            isPresented = false
        }
    }
}

private struct SourceKindTile: View {
    let kind: SourceKind
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SourceIcon(kind: kind, size: 28)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary).font(.system(size: 13))
                    }
                }
                Text(kind.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.foreground)
                Text(kind.subtitle).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(2)
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
