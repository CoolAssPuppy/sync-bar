//
//  MainView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

enum MainSelection: Hashable {
    case welcome
    case notionWorkspace(String)
    case linearAccount(String)
    case googleAccount(String)
    case markdownTarget(String)
    case appleNotesTarget(String)
    case remarkable
}

struct MainView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var uploadCoordinator = UploadCoordinator.shared
    @State private var selection: MainSelection = .remarkable
    @State private var isSettingsOpen = false
    @State private var isLogOpen = false
    @State private var selectedNotebookId: String?

    var body: some View {
        let theme = themeStore.palette
        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                Sidebar(
                    coordinator: coordinator,
                    selection: $selection,
                    onOpenSettings: { isSettingsOpen = true },
                    onOpenLog: { isLogOpen = true }
                )
                .frame(width: 260)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background)
            .overlay(alignment: .bottom) {
                if uploadCoordinator.isUploading {
                    UploadProgressBar(progress: uploadCoordinator.progress)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: uploadCoordinator.isUploading)

            SettingsDrawer(isPresented: $isSettingsOpen)
            SyncLogDrawer(isPresented: $isLogOpen)
            UploadBannerView()
        }
        .frame(minWidth: 880, minHeight: 580)
        .background(WindowChrome(palette: theme))
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear {
            if ledger.remarkableAccount == nil && ledger.notionWorkspaces.isEmpty {
                selection = .welcome
            }
            // Reconcile pairing + refresh off the main thread. The keychain read
            // can be slow and may surface the access prompt; doing it here would
            // block the window from appearing.
            Task { await reconcilePairingThenRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsDrawer)) { _ in
            isSettingsOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSyncLog)) { _ in
            isLogOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectRemarkableView)) { _ in
            selection = .remarkable
        }
        .onReceive(NotificationCenter.default.publisher(for: .remarkableUploadFinished)) { _ in
            refreshFolders()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .welcome:
            WelcomeView(onFinish: { selection = .remarkable })
        case .notionWorkspace(let id):
            NotionWorkspaceDetailView(workspaceId: id)
        case .linearAccount(let id):
            LinearAccountDetailView(accountId: id)
        case .googleAccount(let id):
            GoogleAccountDetailView(accountId: id)
        case .markdownTarget(let id):
            MarkdownTargetDetailView(targetId: id)
        case .appleNotesTarget(let id):
            AppleNotesTargetDetailView(targetId: id)
        case .remarkable:
            if ledger.remarkableAccount != nil {
                NotebookListView(
                    selectedNotebookId: $selectedNotebookId,
                    coordinator: coordinator,
                    onRefresh: refreshFolders
                )
            } else {
                RemarkableDetailView()
            }
        }
    }

    /// Resolves the half-paired edge (an account record but no device token, e.g.
    /// the token was lost) and, when genuinely paired, refreshes the live folder
    /// list. The token is read off the main thread so window open never blocks.
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
                    // Clean up rules left pointing at folders that no longer
                    // exist (e.g. orphaned by the folder/file model change).
                    if !folders.isEmpty {
                        ledger.pruneRules(keepingFolderIds: Set(folders.map(\.id)))
                    }
                }
            } catch {
                await MainActor.run { ledger.updateRemarkableHealth(error: error) }
                Log.ui.error("Notebook refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - Window chrome

private struct WindowChrome: NSViewRepresentable {
    let palette: ThemePalette

    func makeNSView(context: Context) -> ChromeView {
        ChromeView(palette: palette)
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.palette = palette
        nsView.applyChrome()
    }
}

private final class ChromeView: NSView {
    var palette: ThemePalette

    init(palette: ThemePalette) {
        self.palette = palette
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }

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
