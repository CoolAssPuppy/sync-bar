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
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var uploadCoordinator = UploadCoordinator.shared

    @StateObject private var taskCoordinator = TaskSyncCoordinator()
    @State private var tab: ShellTab = .syncs
    @State private var editorTarget: SyncEditorTarget?
    @State private var taskEditorTarget: TaskSyncEditorTarget?
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
        .sheet(item: $taskEditorTarget) { target in
            TaskSyncEditorView(target: target, onClose: { taskEditorTarget = nil })
                .environment(\.theme, themeStore.palette)
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
                onNewTask: { taskEditorTarget = .new },
                onEditTask: { taskEditorTarget = .edit($0) },
                onRefresh: refreshFolders
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
                         badge: ledger.syncFlows.isEmpty ? nil : "\(ledger.syncFlows.count)",
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
