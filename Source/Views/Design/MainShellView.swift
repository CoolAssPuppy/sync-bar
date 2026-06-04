//
//  MainShellView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The redesigned window: a slim rail (Syncs / Connections / Activity /
//  Settings) over the content, with the Sync editor as a sheet and the upload
//  progress bar + result banner as overlays. Replaces the old MainView.
//

import SwiftUI
import AppKit

enum ShellTab: Hashable { case syncs, connections, activity, settings }

struct MainShellView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var uploadCoordinator = UploadCoordinator.shared

    @State private var tab: ShellTab = .syncs
    @State private var editorTarget: SyncEditorTarget?
    @State private var isOnboarding = false

    var body: some View {
        let theme = themeStore.palette
        ZStack(alignment: .top) {
            if isOnboarding {
                OnboardingView(onFinish: {
                    isOnboarding = false; tab = .syncs; refreshFolders()
                })
            } else {
                shell(theme: theme)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(ShellChrome(palette: theme))
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear { firstAppear() }
        .onReceive(NotificationCenter.default.publisher(for: .selectRemarkableView)) { _ in tab = .syncs }
        .onReceive(NotificationCenter.default.publisher(for: .remarkableUploadFinished)) { _ in refreshFolders() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsDrawer)) { _ in tab = .settings }
        .onReceive(NotificationCenter.default.publisher(for: .openSyncLog)) { _ in tab = .activity }
        .sheet(item: $editorTarget) { target in
            SyncEditorView(target: target, coordinator: coordinator, onClose: { editorTarget = nil })
        }
    }

    private func shell(theme: ThemePalette) -> some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                rail(theme: theme)
                Rectangle().fill(theme.divider).frame(width: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background)
            .overlay(alignment: .bottom) {
                if uploadCoordinator.isUploading {
                    UploadProgressBar(progress: uploadCoordinator.progress).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: uploadCoordinator.isUploading)
            UploadBannerView()
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .syncs:
            SyncsHomeView(
                coordinator: coordinator,
                onNew: { editorTarget = .new },
                onEdit: { editorTarget = .edit($0) },
                onRefresh: refreshFolders
            )
        case .connections: ConnectionsView()
        case .activity:    ActivityView()
        case .settings:    SettingsScreen()
        }
    }

    // MARK: Rail

    private func rail(theme: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.primary)
                Text("Sync Bar").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.foreground)
            }
            .padding(.horizontal, 8)
            .padding(.top, 30)
            .padding(.bottom, 22)

            VStack(spacing: 3) {
                RailItem(icon: "arrow.triangle.2.circlepath", label: "Syncs",
                         badge: ledger.syncFlows.isEmpty ? nil : "\(ledger.syncFlows.count)",
                         isActive: tab == .syncs) { tab = .syncs }
                RailItem(icon: "link", label: "Connections",
                         badge: ledger.hasAnyDestination ? "\(ledger.connectedAppCount)" : nil,
                         isActive: tab == .connections) { tab = .connections }
                RailItem(icon: "waveform.path.ecg", label: "Activity", isActive: tab == .activity) { tab = .activity }
            }

            Spacer()

            connectionStatus(theme: theme)
                .padding(.bottom, 4)
            RailItem(icon: "gearshape", label: "Settings", isActive: tab == .settings) { tab = .settings }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: 236)
        .background(theme.surface)
    }

    private func connectionStatus(theme: ThemePalette) -> some View {
        Button(action: { tab = .connections }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(theme))
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor(theme).opacity(0.6), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("reMarkable").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.foreground)
                    Text(statusText).font(.system(size: 10.5)).foregroundStyle(theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ theme: ThemePalette) -> Color {
        if ledger.remarkableAccount == nil { return theme.tertiary }
        if ledger.remarkableNeedsRepair { return theme.destructive }
        if coordinator.isSyncing { return theme.primary }
        return theme.success
    }

    private var statusText: String {
        if ledger.remarkableAccount == nil { return "Not paired" }
        if ledger.remarkableNeedsRepair { return "Disconnected — re-pair" }
        if coordinator.isSyncing { return "Syncing now…" }
        return "Connected"
    }

    // MARK: Lifecycle / data

    private func firstAppear() {
        if ledger.remarkableAccount == nil && !ledger.hasAnyDestination {
            isOnboarding = true
        }
        Task { await reconcilePairingThenRefresh() }
    }

    private func reconcilePairingThenRefresh() async {
        guard ledger.remarkableAccount != nil else { return }
        let hasToken = await Task.detached {
            KeychainStore.shared.value(for: .remarkableDeviceToken)?.isEmpty == false
        }.value
        if !hasToken {
            Log.ui.info("reMarkable account present but no device token — resetting to unpaired")
            ledger.setRemarkableAccount(nil)
            ledger.setFolders([])
            return
        }
        refreshFolders()
    }

    private func refreshFolders() {
        Task {
            let client = RemarkableClientFactory.make()
            do {
                let folders = try await client.listFolders()
                await MainActor.run {
                    ledger.updateRemarkableHealth(error: nil)
                    ledger.setFolders(folders)
                    if !folders.isEmpty { ledger.pruneRules(keepingFolderIds: Set(folders.map(\.id))) }
                }
            } catch {
                await MainActor.run { ledger.updateRemarkableHealth(error: error) }
                Log.ui.error("Notebook refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - Window chrome

private struct ShellChrome: NSViewRepresentable {
    let palette: ThemePalette
    func makeNSView(context: Context) -> ChromeView { ChromeView(palette: palette) }
    func updateNSView(_ nsView: ChromeView, context: Context) { nsView.palette = palette; nsView.applyChrome() }

    final class ChromeView: NSView {
        var palette: ThemePalette
        init(palette: ThemePalette) { self.palette = palette; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyChrome() }
        func applyChrome() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.appearance = palette.nsAppearance
            window.backgroundColor = palette.nsBackground
            window.isMovableByWindowBackground = true
        }
    }
}
