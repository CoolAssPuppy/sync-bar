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

            SettingsDrawer(isPresented: $isSettingsOpen)
            SyncLogDrawer(isPresented: $isLogOpen)
        }
        .frame(minWidth: 880, minHeight: 580)
        .background(WindowChrome(palette: theme))
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear {
            // The device token is the source of truth for "paired". If an
            // account lingers without a token (e.g. the token was lost), the app
            // would otherwise show the mock client's sample notebooks as if they
            // were real. Reset that half-paired state so the pairing screen
            // returns and the user can re-pair.
            let hasToken = KeychainStore.shared.value(for: .remarkableDeviceToken)?.isEmpty == false
            if ledger.remarkableAccount != nil && !hasToken {
                Log.ui.info("reMarkable account present but no device token — resetting to unpaired")
                ledger.setRemarkableAccount(nil)
                ledger.setNotebooks([])
            }
            // Always pull from reMarkable when genuinely paired so the live
            // library is authoritative (and stale notebooks can't mask it).
            if ledger.remarkableAccount != nil {
                refreshNotebooks()
            }
            if ledger.remarkableAccount == nil && ledger.notionWorkspaces.isEmpty {
                selection = .welcome
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsDrawer)) { _ in
            isSettingsOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSyncLog)) { _ in
            isLogOpen = true
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
                    onRefresh: refreshNotebooks
                )
            } else {
                RemarkableDetailView()
            }
        }
    }

    private func refreshNotebooks() {
        Task {
            let client = RemarkableClientFactory.make()
            do {
                let notebooks = try await client.listNotebooks()
                await MainActor.run { ledger.setNotebooks(notebooks) }
            } catch {
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
