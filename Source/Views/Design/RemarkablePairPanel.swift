//
//  RemarkablePairPanel.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Reusable pairing panel: enter an 8-character one-time code to pair (or
//  re-pair) the reMarkable. Used in Connections and in onboarding.
//

import SwiftUI

struct RemarkablePairPanel: View {
    var title: String = "Pair your reMarkable"
    /// Shown as a sheet — provide a close handler. Pass nil to embed inline
    /// (onboarding), where there's no close button.
    var onClose: (() -> Void)? = nil
    /// Called after a successful pair so a host can advance (e.g. onboarding).
    var onPaired: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    private let remarkable = RealRemarkableClient()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(theme.primary)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Sign in at my.remarkable.com, open Connect, and generate an 8-character one-time code.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            CodeBoxField(value: $code, length: 8)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.destructive)
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.destructive)
                }
            }

            HStack(spacing: 10) {
                if let onClose {
                    PillButton(title: "Cancel", filled: false) { onClose() }
                }
                PillButton(title: isPairing ? "Pairing…" : "Pair device", systemImage: "qrcode.viewfinder") {
                    Task { await pair() }
                }
            }
            .opacity(code.count == 8 && !isPairing ? 1 : (isPairing ? 1 : 0.6))
        }
        .padding(28)
        .frame(width: 440)
        .background(theme.surface)
    }

    private func pair() async {
        guard code.count == 8, !isPairing else { return }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let account = try await remarkable.pairDevice(oneTimeCode: code)
            KeychainStore.shared.delete(key: .remarkableUserToken)
            Ledger.shared.setRemarkableAccount(account)
            let folders = try await remarkable.listFolders()
            Ledger.shared.setFolders(folders)
            // A fresh account gives every folder a new id; remap existing rules to
            // the same-named folders so syncs survive the switch instead of going
            // silent ("no notebooks").
            Ledger.shared.reconcileRemarkableRules(withFolders: folders)
            Ledger.shared.updateRemarkableHealth(error: nil)
            Telemetry.capture(.remarkablePaired)
            code = ""
            onPaired?()
            onClose?()
        } catch {
            Telemetry.capture(.remarkablePairFailed)
            errorMessage = Formatters.userMessage(for: error)
        }
    }
}
