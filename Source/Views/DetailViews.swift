//
//  DetailViews.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

// MARK: - Notion workspace

struct NotionWorkspaceDetailView: View {
    let workspaceId: String
    @ObservedObject private var ledger = Ledger.shared

    private var workspace: NotionWorkspace? {
        ledger.notionWorkspaces.first(where: { $0.id == workspaceId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .notion,
            title: workspace?.workspaceName ?? "Workspace",
            connectedAt: workspace?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .notion(let cfg) = config { return cfg.workspaceId == workspaceId }
                return false
            }),
            rename: { newName in ledger.renameNotionWorkspace(id: workspaceId, newName: newName) },
            connectableFolders: ledger.folders,
            connectSource: workspace.map { w in { folder in
                ledger.connect(folder: folder, configuration: .notion(NotionDestinationConfig(
                    workspaceId: w.id, destinationId: "", destinationType: .page,
                    destinationTitle: w.workspaceName, propertyMappings: [:])))
            } },
            disconnect: { ledger.removeNotionWorkspace(id: workspaceId) }
        )
    }
}

// MARK: - Linear account

struct LinearAccountDetailView: View {
    let accountId: String
    @ObservedObject private var ledger = Ledger.shared

    private var account: LinearAccount? {
        ledger.linearAccounts.first(where: { $0.id == accountId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .linear,
            title: account?.name ?? "Linear Team",
            subtitle: account?.organizationName,
            connectedAt: account?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .linear(let cfg) = config { return cfg.workspaceId == accountId }
                return false
            }),
            rename: { newName in ledger.renameLinearAccount(id: accountId, newName: newName) },
            connectableFolders: ledger.folders,
            connectSource: account.map { a in { folder in
                ledger.connect(folder: folder, configuration: .linear(LinearDestinationConfig(
                    workspaceId: a.id, workspaceName: a.name, projectId: nil,
                    projectName: nil, defaultLabel: nil, requiredTags: nil)))
            } },
            disconnect: { ledger.removeLinearAccount(id: accountId) }
        )
    }
}

// MARK: - Google Docs account

struct GoogleAccountDetailView: View {
    let accountId: String
    @ObservedObject private var ledger = Ledger.shared

    private var account: GoogleAccount? {
        ledger.googleAccounts.first(where: { $0.id == accountId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .googleDocs,
            title: account?.displayName ?? "Google Account",
            subtitle: account?.id,
            connectedAt: account?.connectedAt,
            activeBindings: ledger.bindings(matching: { config in
                if case .googleDocs(let cfg) = config { return cfg.accountEmail == accountId }
                return false
            }),
            rename: { newName in ledger.renameGoogleAccount(id: accountId, newName: newName) },
            connectableFolders: ledger.folders,
            connectSource: account.map { a in { folder in
                ledger.connect(folder: folder, configuration: .googleDocs(GoogleDocsDestinationConfig(
                    accountEmail: a.id, folderId: nil, folderName: nil, appendMode: .onePerPage)))
            } },
            disconnect: { ledger.removeGoogleAccount(id: accountId) }
        )
    }
}

// MARK: - Markdown target

struct MarkdownTargetDetailView: View {
    let targetId: String
    @ObservedObject private var ledger = Ledger.shared

    private var target: MarkdownTarget? {
        ledger.markdownTargets.first(where: { $0.id == targetId })
    }

    var body: some View {
        let target = self.target
        DestinationDetailScaffold(
            kind: .markdownFolder,
            title: target?.displayName ?? "Markdown Files",
            subtitle: target.map { ($0.folderPath as NSString).abbreviatingWithTildeInPath },
            connectedAt: target?.connectedAt,
            // Show only the syncs writing to THIS destination's folder.
            activeBindings: ledger.bindings(matching: { config in
                guard case .markdownFolder(let cfg) = config, let target else { return false }
                return cfg.folderPath == target.folderPath
            }),
            connectableFolders: ledger.folders,
            connectSource: target.map { t in { folder in
                ledger.connect(folder: folder, configuration: .markdownFolder(t.defaultConfiguration))
            } },
            disconnect: { ledger.removeMarkdownTarget(id: targetId) }
        )
    }
}

// MARK: - Apple Notes target

struct AppleNotesTargetDetailView: View {
    let targetId: String
    @ObservedObject private var ledger = Ledger.shared

    private var target: AppleNotesTarget? {
        ledger.appleNotesTargets.first(where: { $0.id == targetId })
    }

    var body: some View {
        DestinationDetailScaffold(
            kind: .appleNotes,
            title: "Apple Notes",
            subtitle: "iCloud Notes",
            connectedAt: target?.connectedAt,
            // The folder is per binding now, so this destination represents every
            // Apple Notes sync rather than one folder.
            activeBindings: ledger.bindings(matching: { config in
                if case .appleNotes = config { return true }
                return false
            }),
            connectableFolders: ledger.folders,
            connectSource: target.map { t in { folder in
                ledger.connect(folder: folder, configuration: .appleNotes(AppleNotesDestinationConfig(folderName: t.folderName)))
            } },
            disconnect: { ledger.removeAppleNotesTarget(id: targetId) }
        )
    }
}

// MARK: - reMarkable (still has its own pair-or-list shape)

struct RemarkableDetailView: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var oneTimeCode: String = ""
    @State private var isPairing: Bool = false
    @State private var errorMessage: String?

    private let remarkable = RealRemarkableClient()

    var body: some View {
        if let account = ledger.remarkableAccount {
            // The reMarkable detail when paired is the notebook list; that
            // route is owned by MainView (selection == .remarkable). This
            // branch is a no-op fallback so the view stays valid in previews.
            VStack {
                Text("reMarkable connected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(account.userIdentifier)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
        } else {
            pairForm
                .background(theme.background)
        }
    }

    private var pairForm: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(theme.primary)
                Text("Pair Your reMarkable")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Sign in at my.remarkable.com, open the Connect section, and generate an 8-character one-time code.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            CodeBoxField(value: $oneTimeCode, length: 8)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.destructive)
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.destructive)
                }
            }

            AppPrimaryButton(
                title: isPairing ? "Pairing…" : "Pair device",
                systemImage: "qrcode.viewfinder",
                isDisabled: oneTimeCode.count != 8 || isPairing
            ) {
                Task { await pair() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func pair() async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let account = try await remarkable.pairDevice(oneTimeCode: oneTimeCode)
            ledger.setRemarkableAccount(account)
            let folders = try await remarkable.listFolders()
            ledger.setFolders(folders)
            Telemetry.capture("remarkable.paired")
            oneTimeCode = ""
        } catch {
            Telemetry.capture("remarkable.pair_failed")
            errorMessage = Formatters.userMessage(for: error)
        }
    }
}

