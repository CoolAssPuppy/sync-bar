//
//  TwitterPaywallSheet.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The consent + paywall gate for a paid Sync class. Shown before the Twitter
//  OAuth connect (the add gate) and again when a lapsed paid sync is clicked (the
//  reactivate gate). Reaching the work behind it requires an active entitlement,
//  and — on first add — explicit consent to share the handle + sync counts.
//

import SwiftUI
import AppKit

struct TwitterPaywallSheet: View {
    let feature: PaidFeature
    /// First-add requires the consent checkbox; reactivation (already consented)
    /// does not.
    var requireConsent: Bool = true
    /// Called when the user may proceed (entitled + consented). For the add flow
    /// this kicks off OAuth; for reactivation it simply dismisses.
    let onContinue: () -> Void
    let onClose: () -> Void

    @ObservedObject private var entitlement = EntitlementManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    @State private var consented = false
    @State private var licenseKey = ""
    @State private var activating = false
    @State private var errorMessage: String?
    @State private var showingLicenseField = false

    /// The required consent copy. Exact wording — it is the user's data agreement.
    private let consentCopy = "I agree this source shares personal information with the app maker, such as your Twitter handle and how many times you sync. Your content is never shared."

    private var isEntitled: Bool { entitlement.isEntitled(to: feature) }
    private var canProceed: Bool { isEntitled && (consented || !requireConsent) }

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            header(theme: theme)
            Divider().background(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    priceCard(theme: theme)
                    if requireConsent { consentRow(theme: theme) }
                    if isEntitled {
                        activeNote(theme: theme)
                    } else {
                        subscribeSection(theme: theme)
                    }
                    privacyLink(theme: theme)
                }
                .padding(20)
            }
            Divider().background(theme.divider)
            footer(theme: theme)
        }
        .frame(width: 480, height: 480)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: Header

    private func header(theme: ThemePalette) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(feature.displayName) is a paid source")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.foreground)
                Text("Syncing \(feature.displayName) uses a paid API.")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.foreground)
                    .frame(width: 28, height: 28).background(Circle().fill(theme.card))
                    .overlay(Circle().strokeBorder(theme.borderStrong, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Price

    private func priceCard(theme: ThemePalette) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 18)).foregroundStyle(theme.primary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.monthlyPriceLabel)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.foreground)
                Text("A flat monthly subscription for syncing your Twitter.")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    // MARK: Consent

    private func consentRow(theme: ThemePalette) -> some View {
        Button(action: { consented.toggle() }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: consented ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(consented ? theme.primary : theme.muted)
                Text(consentCopy)
                    .font(.system(size: 11)).foregroundStyle(theme.foregroundSoft)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Entitled / not

    private func activeNote(theme: ThemePalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.success).font(.system(size: 13))
            Text("Subscription active. You're all set.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.foregroundSoft)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func subscribeSection(theme: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AppPrimaryButton(title: "Subscribe (\(feature.monthlyPriceLabel))",
                             systemImage: "arrow.up.forward.app",
                             isDisabled: AuthSecrets.polarCheckoutURL == nil) { subscribe() }
            if AuthSecrets.polarCheckoutURL == nil {
                Text("Subscribing isn't available in this build yet.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }

            // The license path is for the few who already paid, so it stays
            // collapsed behind a link until asked for.
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showingLicenseField.toggle() } }) {
                HStack(spacing: 4) {
                    Text("Already have a license key?")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: showingLicenseField ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.primary)
            }
            .buttonStyle(.plain)

            if showingLicenseField {
                HStack(spacing: 8) {
                    TextField("Paste your license key", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                    AppSecondaryButton(title: activating ? "Activating…" : "Activate", tint: .primary) { activate() }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.destructive)
                }
            }
        }
    }

    private func privacyLink(theme: ThemePalette) -> some View {
        Link(destination: AuthSecrets.privacyPolicyURL) {
            Text("Privacy policy")
                .font(.system(size: 11)).foregroundStyle(theme.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private func footer(theme: ThemePalette) -> some View {
        HStack {
            Spacer()
            AppSecondaryButton(title: "Cancel") { onClose() }
            AppPrimaryButton(title: "Continue", systemImage: "arrow.right", isDisabled: !canProceed) {
                onContinue()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14).background(theme.surface)
    }

    // MARK: Actions

    private func subscribe() {
        guard let url = AuthSecrets.polarCheckoutURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func activate() {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !activating else { return }
        activating = true
        errorMessage = nil
        Task {
            do {
                try await entitlement.activate(key: key, for: feature)
                activating = false
            } catch {
                activating = false
                errorMessage = Formatters.userMessage(for: error)
            }
        }
    }
}
