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

enum ShellTab: Hashable { case syncs, connections, activity }

struct MainShellView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject var taskCoordinator: TaskSyncCoordinator
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var uploadCoordinator = UploadCoordinator.shared

    /// Every sync shown on the Syncs home: one-way flows plus two-way task syncs.
    private var syncCount: Int { ledger.syncFlows.count + ledger.taskSyncs.count }

    @State private var tab: ShellTab = .syncs
    @State private var editorTarget: SyncEditorTarget?
    @State private var isOnboarding = false
    @State private var isSettingsOpen = false

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
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsDrawer)) { _ in isSettingsOpen = true }
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
            SettingsDrawer(isPresented: $isSettingsOpen)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .syncs:
            SyncsHomeView(
                coordinator: coordinator,
                taskCoordinator: taskCoordinator,
                onNew: { editorTarget = .new },
                onEdit: { editorTarget = .edit($0) },
                onEditTask: { editorTarget = .editTask($0) }
            )
        case .connections: ConnectionsView()
        case .activity:    ActivityView()
        }
    }

    // MARK: Rail

    private func rail(theme: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 24, height: 24)
                Text("Sync Bar").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.foreground)
            }
            .padding(.horizontal, 8)
            .padding(.top, 30)
            .padding(.bottom, 22)

            VStack(spacing: 3) {
                RailItem(icon: "arrow.triangle.2.circlepath", label: "Syncs",
                         badge: syncCount > 0 ? "\(syncCount)" : nil,
                         isActive: tab == .syncs) { tab = .syncs }
                RailItem(icon: "link", label: "Connections",
                         badge: ledger.connectionCount > 0 ? "\(ledger.connectionCount)" : nil,
                         isActive: tab == .connections) { tab = .connections }
                RailItem(icon: "waveform.path.ecg", label: "Activity", isActive: tab == .activity) { tab = .activity }
            }

            Spacer()

            RailItem(icon: "gearshape", label: "Settings", isActive: false) { isSettingsOpen = true }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: 236)
        .background(theme.surface)
    }

    // MARK: Lifecycle / data

    private func firstAppear() {
        // First-run guidance now lives in the Syncs home hero ("Add your first
        // Source"), so the dedicated onboarding screen isn't forced here.
        Task { await reconcilePairingThenRefresh() }
    }

    private func reconcilePairingThenRefresh() async {
        guard ledger.remarkableAccount != nil else { return }
        let hasToken = await Task.detached {
            KeychainStore.shared.value(for: .remarkableDeviceToken)?.isEmpty == false
        }.value
        if !hasToken {
            // The device token read came back empty. Don't assume the pairing is
            // gone — a keychain read can fail transiently (a locked keychain, or a
            // dev rebuild whose new code signature isn't yet trusted for the
            // item). Wiping the account here would silently drop the source while
            // leaving its syncs behind. Flag a re-pair instead and keep the
            // pairing record so a later launch (or a granted keychain prompt) can
            // recover it.
            Log.ui.info("reMarkable account present but device token unreadable — flagging re-pair, keeping the pairing")
            ledger.setRemarkableNeedsRepair(true)
            return
        }
        ledger.setRemarkableNeedsRepair(false)
        refreshFolders()
    }

    /// Walks the paired reMarkable and caches its folder list. Gated on a real
    /// device token, because without one `RemarkableClientFactory` hands back the
    /// mock client, and its three sample folders would be cached as if they were
    /// real — then rules would be reconciled against them. The client is built per
    /// call rather than held, so a refresh straight after pairing gets the live one.
    private func refreshFolders() {
        Task {
            let hasToken = await Task.detached {
                KeychainStore.shared.value(for: .remarkableDeviceToken)?.isEmpty == false
            }.value
            guard hasToken else { return }
            let client = RemarkableClientFactory.make()
            do {
                let folders = try await client.listFolders()
                await MainActor.run {
                    ledger.updateRemarkableHealth(error: nil)
                    ledger.setFolders(folders)
                    // Remap rules orphaned by an account switch; never delete on a
                    // missing folder id (that would silently destroy syncs after a
                    // re-pair, since every folder id changes).
                    if !folders.isEmpty { ledger.reconcileRemarkableRules(withFolders: folders) }
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
