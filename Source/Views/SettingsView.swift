//
//  SettingsView.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var entitlement = EntitlementManager.shared
    @Environment(\.theme) private var theme

    @State private var openaiKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var telemetryOptedIn = Telemetry.isOptedIn
    @State private var licenseKeyInput: String = ""
    @State private var activatingLicense = false
    @State private var licenseError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    generalCard
                    ocrCard
                    resyncCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    folderVisibilityCard
                    subscriptionCard
                    notificationsCard
                    updatesCard
                    contactCard
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
        .onAppear {
            // Load the stored keys off the main thread so the Settings drawer
            // opens instantly instead of blocking on keychain reads.
            Task {
                let keys = await Task.detached {
                    (KeychainStore.shared.value(for: .openaiApiKey) ?? "",
                     KeychainStore.shared.value(for: .anthropicApiKey) ?? "")
                }.value
                openaiKey = keys.0
                anthropicKey = keys.1
            }
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
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Send anonymous usage data",
                              description: "Anonymous metrics to improve Sync Bar. Paid Twitter syncs separately report usage (your handle and sync counts) you consented to when adding the source.") {
                    Toggle("", isOn: Binding(
                        get: { telemetryOptedIn },
                        set: { newValue in
                            telemetryOptedIn = newValue
                            Telemetry.setOptedIn(newValue)
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
            }
        }
    }

    // MARK: OCR

    private var ocrCard: some View {
        AppCard("OCR Provider") {
            VStack(spacing: 0) {
                AppSettingRow("Default provider", description: "Vision runs on-device. OpenAI and Anthropic use your own API key.") {
                    Picker("", selection: $settings.ocrProvider) {
                        ForEach(OcrProviderChoice.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
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

    // MARK: Resync

    private var resyncCard: some View {
        AppCard("Resync") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reset your sync database")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Delete the internal database that tracks syncs. Warning: this will resync everything.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                AppSecondaryButton(title: "Resync notes", systemImage: "arrow.triangle.2.circlepath", tint: .warning) {
                    Ledger.shared.resetSyncDatabase()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Folder visibility

    private var folderVisibilityCard: some View {
        AppCard("Folder visibility") {
            VStack(spacing: 0) {
                AppSettingRow("Ignore Unfiled notes",
                              description: "Notes that are not in a folder show up in Unfiled.") {
                    Toggle("", isOn: $settings.ignoreUnfiledNotes)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
            }
        }
    }

    // MARK: Subscription

    private var subscriptionCard: some View {
        AppCard("Subscription") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Twitter")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.foreground)
                    Spacer()
                    subscriptionBadge
                }
                Text(subscriptionBlurb)
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entitlement.state(for: .twitter) == .active {
                    HStack(spacing: 8) {
                        AppSecondaryButton(title: "Manage subscription", systemImage: "creditcard",
                                           tint: .primary) { openPortal() }
                            .disabled(AuthSecrets.polarPortalURL == nil)
                        AppSecondaryButton(title: "Remove key", systemImage: "trash",
                                           tint: .warning) { removeLicense() }
                    }
                } else {
                    AppPrimaryButton(title: "Subscribe", systemImage: "arrow.up.forward.app",
                                     isDisabled: AuthSecrets.polarCheckoutURL == nil) { openCheckout() }
                    HStack(spacing: 6) {
                        SecureField("Paste license key", text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)
                        AppSecondaryButton(title: activatingLicense ? "Activating…" : "Activate",
                                           tint: .primary) { activateLicense() }
                    }
                    if let licenseError {
                        Text(licenseError).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.destructive)
                    }
                }

                Link(destination: AuthSecrets.privacyPolicyURL) {
                    Text("Privacy policy").font(.system(size: 11)).foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subscriptionBadge: some View {
        let (label, color): (String, Color) = {
            switch entitlement.state(for: .twitter) {
            case .active: return ("Active", theme.success)
            case .lapsed: return ("Inactive", theme.warning)
            case .none:   return ("Not subscribed", theme.muted)
            }
        }()
        return Text(label)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var subscriptionBlurb: String {
        switch entitlement.state(for: .twitter) {
        case .active: return "$6.99/month. Your Twitter syncs are running."
        case .lapsed: return "Your subscription lapsed. Twitter syncs are paused until you re-subscribe."
        case .none:   return "Twitter is a paid source: $6.99/month."
        }
    }

    private func openCheckout() {
        if let url = AuthSecrets.polarCheckoutURL { NSWorkspace.shared.open(url) }
    }
    private func openPortal() {
        if let url = AuthSecrets.polarPortalURL { NSWorkspace.shared.open(url) }
    }
    private func removeLicense() {
        Task { await entitlement.removeLicense(for: .twitter) }
    }
    private func activateLicense() {
        let key = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !activatingLicense else { return }
        activatingLicense = true
        licenseError = nil
        Task {
            do {
                try await entitlement.activate(key: key, for: .twitter)
                activatingLicense = false
                licenseKeyInput = ""
            } catch {
                activatingLicense = false
                licenseError = Formatters.userMessage(for: error)
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
                AppSettingRow("Check for updates", description: nil) {
                    AppSecondaryButton(title: "Check now", systemImage: "arrow.down.circle") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Demo mode", description: nil) {
                    Toggle("", isOn: Binding(
                        get: { ledger.isDemoMode },
                        set: { ledger.setDemoMode($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
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
                           url: "https://github.com/CoolAssPuppy/sync-bar")
                contactRow(systemName: "square.grid.2x2.fill",
                           title: "See all my apps",
                           url: "https://www.strategicnerds.com/apps")
                coffeeRow
                contactRow(systemName: "book.closed.fill",
                           title: "Buy my book",
                           url: "https://www.strategicnerds.com/picksandshovels")
            }
        }
    }

    /// "Buy me coffee" with two payment links so there's a single coffee entry.
    private var coffeeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .frame(width: 16, alignment: .center)
            HStack(spacing: 0) {
                Text("Buy me coffee ")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foreground)
                Text("(")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                coffeeLink(title: "Venmo", url: "https://venmo.com/u/coolasspuppy")
                Text(", ")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                coffeeLink(title: "Revolut", url: "https://revolut.me/coolasspuppy")
                Text(")")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func coffeeLink(title: String, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(staticString: "https://strategicnerds.com")) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.primary)
        }
        .buttonStyle(.plain)
    }

    private func contactRow(systemName: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(staticString: "https://strategicnerds.com")) {
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
