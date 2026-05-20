//
//  SettingsView.swift
//  Sync Bar
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
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    notificationsCard
                    updatesCard
                    developerCard
                    contactCard
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
                AppSettingRow("Launch at startup", description: "Start Sync Bar when you log in.") {
                    Toggle("", isOn: $settings.launchAtStartup)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Sync interval", description: "How often Sync Bar polls reMarkable for new pages.") {
                    Picker("", selection: $settings.syncIntervalSeconds) {
                        ForEach(AppSettings.intervalOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Open main window on launch", description: "Otherwise Sync Bar lives in the menu bar only.") {
                    Toggle("", isOn: $settings.openWindowOnLaunch)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
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
                Button(action: {
                    KeychainStore.shared.set(value: binding.wrappedValue, for: keychainKey)
                }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.cardInset)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(theme.borderStrong, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Save key")
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
                AppSettingRow("Version", description: "Installed build of Sync Bar.") {
                    Text(UpdaterManager.shared.currentVersion)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.muted)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Check for updates",
                              description: "Sparkle pulls from coolasspuppy.com/syncbar-updates and verifies the signature.") {
                    AppSecondaryButton(title: "Check now", systemImage: "arrow.down.circle") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                }
            }
        }
    }

    // MARK: Developer

    private var developerCard: some View {
        AppCard("Developer") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Populate the app with sample notebooks, connected destinations, rules, and a sync history so you can explore or screenshot every screen without a real device.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    AppSecondaryButton(title: "Load sample data", systemImage: "wand.and.stars") {
                        DemoData.load()
                    }
                    AppSecondaryButton(title: "Clear sample data", systemImage: "trash", tint: .destructive) {
                        DemoData.clear()
                    }
                }
            }
        }
    }

    // MARK: Contact

    private var contactCard: some View {
        AppCard("Contact") {
            VStack(alignment: .leading, spacing: 10) {
                contactRow(systemName: "ladybug.fill",
                           title: "bugs@strategicnerds.com",
                           url: "mailto:bugs@strategicnerds.com")
                contactRow(systemName: "chevron.left.forwardslash.chevron.right",
                           title: "Contribute on GitHub",
                           url: "https://github.com/CoolAssPuppy/syncbar")
                contactRow(systemName: "cup.and.saucer.fill",
                           title: "Buy me coffee",
                           url: "https://venmo.com/u/coolasspuppy")
                contactRow(systemName: "book.closed.fill",
                           title: "Buy my book",
                           url: "https://www.strategicnerds.com/picksandshovels")
            }
        }
    }

    private func contactRow(systemName: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(string: "https://strategicnerds.com")!) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primary)
            }
        }
        .buttonStyle(.plain)
    }

}
