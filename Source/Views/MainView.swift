//
//  MainView.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

enum MainSelection: Hashable {
    case welcome
    case notebooks
    case syncLog
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
    @State private var selection: MainSelection = .notebooks
    @State private var isSettingsOpen = false
    @State private var selectedNotebookId: String?

    var body: some View {
        let theme = themeStore.palette
        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                Sidebar(
                    selection: $selection,
                    onOpenSettings: { isSettingsOpen = true }
                )
                .frame(width: 260)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background)

            SettingsDrawer(isPresented: $isSettingsOpen)
        }
        .frame(minWidth: 880, minHeight: 580)
        .background(WindowChrome(palette: theme))
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear {
            if ledger.notebooks.isEmpty && ledger.remarkableAccount != nil {
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
            selection = .syncLog
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .welcome:
            WelcomeView(onFinish: { selection = .notebooks })
        case .notebooks:
            NotebookListView(
                selectedNotebookId: $selectedNotebookId,
                coordinator: coordinator,
                onRefresh: refreshNotebooks
            )
        case .syncLog:
            SyncLogView()
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
            RemarkableDetailView()
        }
    }

    private func refreshNotebooks() {
        Task {
            let client = MockRemarkableClient()
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
