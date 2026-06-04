//
//  SettingsScreen.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Redesigned settings as a first-class tab. Single scrollable column of
//  grouped cards. Global options only — per-sync options live in the editor.
//

import SwiftUI

struct SettingsScreen: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var updater = UpdaterManager.shared
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalCard
                    transcriptionCard
                    notificationsCard
                    appearanceCard
                    updatesCard
                    advancedCard
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .background(theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Settings").font(.system(size: 24, weight: .bold)).foregroundStyle(theme.foreground)
            Text("How Sync Bar runs, everywhere").font(.system(size: 13)).foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 14)
    }

    // MARK: General

    private var generalCard: some View {
        AppCard("General") {
            VStack(spacing: 0) {
                toggleRow("Launch at login", isOn: $settings.launchAtStartup)
                divider
                row("Sync every") {
                    Picker("", selection: $settings.syncIntervalSeconds) {
                        ForEach(AppSettings.intervalOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }.labelsHidden().fixedSize()
                }
                divider
                toggleRow("Open the window at launch", isOn: $settings.openWindowOnLaunch)
                divider
                toggleRow("Pause all syncing", subtitle: "Nothing syncs until you turn this back off", isOn: $settings.pauseSyncing)
            }
        }
    }

    // MARK: Transcription

    private var transcriptionCard: some View {
        AppCard("Transcription") {
            VStack(spacing: 0) {
                row("Default OCR engine") {
                    Picker("", selection: $settings.ocrProvider) {
                        ForEach(OcrProviderChoice.allCases) { p in Text(p.label).tag(p) }
                    }.labelsHidden().fixedSize()
                }
                if settings.ocrProvider == .openai {
                    divider
                    keyRow("OpenAI API key", key: .openaiApiKey)
                }
                if settings.ocrProvider == .anthropic {
                    divider
                    keyRow("Anthropic API key", key: .anthropicApiKey)
                }
                if settings.ocrProvider != .vision {
                    divider
                    row("Model override") {
                        TextField("default", text: $settings.ocrModel)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
            }
        }
    }

    // MARK: Notifications

    private var notificationsCard: some View {
        AppCard("Notifications") {
            VStack(spacing: 0) {
                toggleRow("Notify when a sync succeeds", isOn: $settings.notifyOnSuccess)
                divider
                toggleRow("Notify when a sync fails", isOn: $settings.notifyOnFailure)
                divider
                toggleRow("Hide loose notes", subtitle: "Ignore the synthetic Unfiled folder", isOn: $settings.ignoreUnfiledNotes)
            }
        }
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        AppCard("Appearance") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { t in
                        ThemeSwatch(theme: t, isSelected: themeStore.current == t) { themeStore.current = t }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Updates

    private var updatesCard: some View {
        AppCard("Updates") {
            row("Sync Bar \(updater.currentVersion)") {
                HStack(spacing: 10) {
                    if let last = updater.lastCheckedAt {
                        Text("Checked \(Formatters.relativeLabel(for: last))")
                            .font(.system(size: 12)).foregroundStyle(theme.tertiary)
                    }
                    AppSecondaryButton(title: "Check for updates", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedCard: some View {
        AppCard("Advanced") {
            row("Reset sync history") {
                AppSecondaryButton(title: confirmingReset ? "Tap again to confirm" : "Reset…", tint: .destructive) {
                    if confirmingReset { ledger.resetSyncDatabase(); confirmingReset = false }
                    else { confirmingReset = true }
                }
            }
        }
    }

    // MARK: Row helpers

    private var divider: some View { Rectangle().fill(theme.dividerSubtle).frame(height: 1) }

    private func row<Trailing: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(theme.tertiary) }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 11)
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, subtitle: subtitle) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(theme.primary)
        }
    }

    private func keyRow(_ title: String, key: KeychainStore.Key) -> some View {
        row(title) { TokenField(title: title, keychainKey: key) }
    }
}

private struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.theme) private var current

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.palette.background)
                    Circle().fill(theme.palette.primary).frame(width: 16, height: 16)
                }
                .frame(width: 54, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? current.primary : current.border, lineWidth: isSelected ? 2 : 1)
                )
                Text(theme.label).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? current.foreground : current.muted)
            }
        }
        .buttonStyle(.plain)
    }
}
