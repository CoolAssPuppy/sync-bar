//
//  WelcomeView.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct WelcomeView: View {
    var onFinish: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var step: Step = .welcome
    @State private var oneTimeCode: String = ""
    @State private var isPairing: Bool = false
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?

    private let remarkable = RealRemarkableClient()

    enum Step {
        case welcome
        case pairRemarkable
        case connectNotion
        case done
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                stepBadge
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    // MARK: Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:        welcomeStep
        case .pairRemarkable: pairStep
        case .connectNotion:  notionStep
        case .done:           doneStep
        }
    }

    private var stepBadge: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { index in
                Capsule()
                    .fill(index <= currentStepIndex ? theme.primary : theme.cardElevated)
                    .frame(width: index == currentStepIndex ? 22 : 10, height: 4)
                    .animation(.easeOut(duration: 0.18), value: currentStepIndex)
            }
        }
    }

    private var currentStepIndex: Int {
        switch step {
        case .welcome:        return 0
        case .pairRemarkable: return 1
        case .connectNotion:  return 2
        case .done:           return 3
        }
    }

    // MARK: Step views

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            BrandMark().scaleEffect(2.6).padding(.bottom, 8)
            Text("Welcome to Sync Bar")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("Sync your reMarkable handwritten notes straight into Notion. Nothing leaves your machine without your say-so.")
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                AppPrimaryButton(title: "Get started", systemImage: "arrow.right") {
                    step = .pairRemarkable
                }
                AppSecondaryButton(title: "Skip onboarding") { onFinish() }
            }
            .padding(.top, 4)
        }
    }

    private var pairStep: some View {
        AppCard("Step 2 · Pair your reMarkable") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in at my.remarkable.com, open the *Connect* section, and generate an 8-character one-time code. Paste it below.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)

                TextField("8-character one-time code", text: $oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 280)

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.destructive)
                        Text(errorMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.destructive)
                    }
                }

                HStack(spacing: 10) {
                    AppPrimaryButton(title: isPairing ? "Pairing…" : "Pair device", systemImage: "qrcode.viewfinder", isDisabled: oneTimeCode.count < 4 || isPairing) {
                        Task { await pairDevice() }
                    }
                    AppSecondaryButton(title: "I'll do this later") {
                        step = .connectNotion
                    }
                }
            }
        }
    }

    private var notionStep: some View {
        AppCard("Step 3 · Connect a Notion workspace") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Authorize Sync Bar to read the pages and databases you want to sync into. You can connect more workspaces any time.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)

                if !AuthSecrets.isNotionConfigured {
                    Text("Notion OAuth isn't configured in this build. Add its client credentials (see the README) and rebuild, or skip for now.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.warning)
                }
                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.destructive)
                        Text(errorMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.destructive)
                    }
                }

                HStack(spacing: 10) {
                    AppPrimaryButton(title: isConnecting ? "Connecting…" : "Connect Notion", systemImage: "link", isDisabled: isConnecting || !AuthSecrets.isNotionConfigured) {
                        Task { await connectNotion() }
                    }
                    AppSecondaryButton(title: "I'll do this later") {
                        step = .done
                    }
                }

                if !ledger.notionWorkspaces.isEmpty {
                    Divider().background(theme.divider).padding(.vertical, 4)
                    Text("Connected so far")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.tertiary)
                        .textCase(.uppercase)
                    ForEach(ledger.notionWorkspaces) { workspace in
                        HStack {
                            Text("\(workspace.workspaceIcon ?? "🌌") \(workspace.workspaceName)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.foreground)
                            Spacer()
                            StatusPill(label: "Connected", kind: .success)
                        }
                    }
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.primary.opacity(0.15))
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 70, height: 70)

            Text("You're set up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text(doneSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            AppPrimaryButton(title: "Open notebooks", systemImage: "arrow.right") { onFinish() }
        }
        .padding(.top, 20)
    }

    private var doneSubtitle: String {
        if ledger.remarkableAccount == nil {
            return "Once your reMarkable arrives, return to Sync Bar and tap Connect reMarkable in the sidebar."
        }
        return "We'll keep syncing on the schedule you choose in Settings. You can pause from the menu bar at any time."
    }

    // MARK: Actions

    private func pairDevice() async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let account = try await remarkable.pairDevice(oneTimeCode: oneTimeCode)
            ledger.setRemarkableAccount(account)
            let notebooks = try await remarkable.listNotebooks()
            ledger.setNotebooks(notebooks)
            step = .connectNotion
        } catch {
            errorMessage = Formatters.userMessage(for: error)
        }
    }

    private func connectNotion() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let workspace = try await NotionAuthService.shared.connect()
            ledger.upsertNotionWorkspace(workspace)
            step = .done
        } catch OAuthError.userCancelled {
            // User backed out of the browser flow; stay on this step.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
