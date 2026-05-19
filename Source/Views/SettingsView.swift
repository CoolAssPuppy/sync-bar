//
//  SettingsView.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var openaiKey: String = ""
    @State private var anthropicKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    generalCard
                    ocrCard
                    accountsCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    notificationsCard
                    updatesCard
                    dataCard
                    advancedCard
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
        .onAppear {
            openaiKey = KeychainStore.shared.value(for: .openaiApiKey) ?? ""
            anthropicKey = KeychainStore.shared.value(for: .anthropicApiKey) ?? ""
        }
    }

    // MARK: General

    private var generalCard: some View {
        AppCard("General") {
            VStack(spacing: 0) {
                AppSettingRow("Launch at startup", description: "Start SyncNerds when you log in.") {
                    Toggle("", isOn: $settings.launchAtStartup)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Sync interval", description: "How often SyncNerds polls reMarkable for new pages.") {
                    Picker("", selection: $settings.syncIntervalSeconds) {
                        ForEach(AppSettings.intervalOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Open main window on launch", description: "Otherwise SyncNerds lives in the menu bar only.") {
                    Toggle("", isOn: $settings.openWindowOnLaunch)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Appearance", description: "Switch between themes any time from the menu bar.") {
                    Picker("", selection: Binding(
                        get: { ThemeStore.shared.current },
                        set: { ThemeStore.shared.current = $0 }
                    )) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
        }
    }

    // MARK: OCR

    private var ocrCard: some View {
        AppCard("OCR provider") {
            VStack(spacing: 0) {
                AppSettingRow("Default provider", description: "Vision runs on-device. OpenAI and Anthropic use your own API key.") {
                    Picker("", selection: $settings.ocrProvider) {
                        ForEach(OcrProviderChoice.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                if settings.ocrProvider == .openai {
                    AppRowDivider().padding(.vertical, 10)
                    keyRow(title: "OpenAI API key", binding: $openaiKey, keychainKey: .openaiApiKey)
                }
                if settings.ocrProvider == .anthropic {
                    AppRowDivider().padding(.vertical, 10)
                    keyRow(title: "Anthropic API key", binding: $anthropicKey, keychainKey: .anthropicApiKey)
                }
                if settings.ocrProvider != .vision {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Model", description: "Optional. Leave blank to use the provider default.") {
                        TextField("e.g. gpt-4o-mini", text: $settings.ocrModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }
            }
        }
    }

    private func keyRow(title: LocalizedStringKey, binding: Binding<String>, keychainKey: KeychainStore.Key) -> some View {
        AppSettingRow(title, description: "Stored securely in your iCloud Keychain.") {
            HStack(spacing: 6) {
                SecureField("sk-…", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                AppSecondaryButton(title: "Save", systemImage: "checkmark") {
                    KeychainStore.shared.set(value: binding.wrappedValue, for: keychainKey)
                }
            }
        }
    }

    // MARK: Accounts

    private var accountsCard: some View {
        AppCard("Accounts") {
            VStack(spacing: 0) {
                AppSettingRow("reMarkable", description: ledger.remarkableAccount == nil ? "Not paired" : "Paired") {
                    if let account = ledger.remarkableAccount {
                        Text(account.userIdentifier)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.muted)
                    } else {
                        AppSecondaryButton(title: "Pair", systemImage: "qrcode.viewfinder") {
                            NotificationCenter.default.post(name: .openPairRemarkable, object: nil)
                        }
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Notion workspaces",
                              description: ledger.notionWorkspaces.isEmpty
                                ? "No workspaces connected"
                                : "\(ledger.notionWorkspaces.count) connected") {
                    AppSecondaryButton(title: "Add", systemImage: "plus") {
                        Task {
                            let workspace = try? await MockNotionClient()
                                .connectMockWorkspace(label: "Workspace \(ledger.notionWorkspaces.count + 1)")
                            if let workspace { ledger.upsertNotionWorkspace(workspace) }
                        }
                    }
                }
                ForEach(ledger.notionWorkspaces) { workspace in
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow(LocalizedStringKey(workspace.workspaceName), description: nil) {
                        AppSecondaryButton(title: "Disconnect", tint: .destructive) {
                            ledger.removeNotionWorkspace(id: workspace.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: Notifications

    private var notificationsCard: some View {
        AppCard("Notifications") {
            VStack(spacing: 0) {
                AppSettingRow("Notify on sync failure",
                              description: "Posts a banner when a rule run errors out.") {
                    Toggle("", isOn: $settings.notifyOnFailure)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Notify on sync success",
                              description: "Quiet by default. Turn on to celebrate every successful sync.") {
                    Toggle("", isOn: $settings.notifyOnSuccess)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
            }
        }
    }

    // MARK: Updates

    private var updatesCard: some View {
        AppCard("Updates") {
            VStack(spacing: 0) {
                AppSettingRow("Version", description: "Installed build of SyncNerds.") {
                    Text(UpdaterManager.shared.currentVersion)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.muted)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Check for updates",
                              description: "Sparkle pulls from coolasspuppy.com/syncnerds-updates and verifies the signature.") {
                    AppSecondaryButton(title: "Check now", systemImage: "arrow.down.circle") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                }
            }
        }
    }

    // MARK: Data

    private var dataCard: some View {
        AppCard("Data") {
            VStack(spacing: 0) {
                AppSettingRow("Export ledger as JSON",
                              description: "All accounts, rules, and recent events as a snapshot.") {
                    AppSecondaryButton(title: "Export…", systemImage: "square.and.arrow.up") {
                        exportLedger()
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Clear sync log",
                              description: "Removes the local event history. CloudKit data is untouched.") {
                    AppSecondaryButton(title: "Clear", tint: .destructive) {
                        ledger.clearEvents()
                    }
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedCard: some View {
        AppCard("Advanced") {
            VStack(spacing: 0) {
                AppSettingRow("Pause syncing",
                              description: "Stop the background timer until you flip this back off.") {
                    Toggle("", isOn: $settings.pauseSyncing)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Reset settings to defaults",
                              description: "Restores every preference. Rules and accounts are untouched.") {
                    AppSecondaryButton(title: "Reset", tint: .destructive) {
                        settings.resetToDefaults()
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func exportLedger() {
        guard let data = ledger.exportSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "syncnerds-ledger.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
