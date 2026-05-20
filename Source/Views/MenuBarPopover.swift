//
//  MenuBarPopover.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct MenuBarPopoverActions {
    var syncNow: (String?, String?) -> Void   // ruleId, bindingId
    var openMainWindow: () -> Void
    var openSettings: () -> Void
    var openNotionUrl: (URL) -> Void
    var togglePause: () -> Void
    var quit: () -> Void
}

struct MenuBarPopover: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var settings = AppSettings.shared

    let actions: MenuBarPopoverActions

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            header(theme: theme)
            Divider().background(theme.divider)
            content
            Divider().background(theme.divider)
            footer(theme: theme)
        }
        .frame(width: 380)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: Header

    private func header(theme: ThemePalette) -> some View {
        HStack(spacing: 10) {
            BrandMark()

            VStack(alignment: .leading, spacing: 1) {
                Text("Sync Bar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor(theme: theme))
                        .frame(width: 6, height: 6)
                        .shadow(color: statusDotColor(theme: theme).opacity(0.5), radius: 4)
                    Text(headerStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                }
            }

            Spacer(minLength: 8)

            if coordinator.isSyncing {
                Text("Syncing…")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.primary.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(theme.primary.opacity(0.3), lineWidth: 1))
            } else if settings.pauseSyncing {
                StatusPill(label: "Paused", kind: .warning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.surface)
    }

    private var headerStatusText: String {
        if settings.pauseSyncing { return "Syncing paused" }
        switch ledger.rules.count {
        case 0:  return "No rules configured"
        case 1:  return "1 rule configured"
        default: return "\(ledger.rules.count) rules configured"
        }
    }

    private func statusDotColor(theme: ThemePalette) -> Color {
        if settings.pauseSyncing { return theme.warning }
        if coordinator.isSyncing  { return theme.primary }
        if ledger.rules.isEmpty   { return theme.tertiary }
        return theme.success
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        // Cap the dropdown at the 10 most recently synced rules so it never
        // grows unwieldy; the full list lives in the main window.
        let visibleRules = Array(
            ledger.rules
                .filter { !$0.destinations.isEmpty }
                .sorted { ($0.aggregateLastRunAt ?? .distantPast) > ($1.aggregateLastRunAt ?? .distantPast) }
                .prefix(10)
        )
        if visibleRules.isEmpty {
            EmptyRulesState(onOpen: actions.openMainWindow)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                listLabel
                ForEach(visibleRules) { rule in
                    SyncRuleCard(
                        rule: rule,
                        isActive: coordinator.activeRuleId == rule.id,
                        onSyncRule: { actions.syncNow(rule.id, nil) },
                        onOpenWindow: actions.openMainWindow
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
    }

    private var listLabel: some View {
        HStack {
            Text("RULES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let lastTick = coordinator.lastTickAt {
                Text("Last run \(Formatters.shortTime.string(from: lastTick))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let nextTick = coordinator.nextTickAt {
                Text("Next \(Formatters.shortTime.string(from: nextTick))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    // MARK: Footer

    private func footer(theme: ThemePalette) -> some View {
        HStack(spacing: 4) {
            AppIconButton(
                systemName: "arrow.triangle.2.circlepath",
                help: "Sync all rules now",
                spinOnTap: true
            ) { actions.syncNow(nil, nil) }

            AppIconButton(
                systemName: settings.pauseSyncing ? "play.fill" : "pause.fill",
                help: settings.pauseSyncing ? "Resume syncing" : "Pause syncing"
            ) { actions.togglePause() }

            AppIconButton(systemName: "macwindow", help: "Open Sync Bar") { actions.openMainWindow() }
            AppIconButton(systemName: "gearshape", help: "Settings (⌘,)") { actions.openSettings() }

            Spacer(minLength: 0)
            ThemeStrip()
            Spacer(minLength: 0)

            AppIconButton(systemName: "power", help: "Quit Sync Bar") { actions.quit() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(theme.surface)
    }
}

// MARK: - Rule card

private struct SyncRuleCard: View {
    let rule: SyncRule
    let isActive: Bool
    let onSyncRule: () -> Void
    let onOpenWindow: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            // Stacked destination icons that hint at the binding count at a
            // glance without the noise of full mini-rows.
            DestinationIconStack(kinds: rule.destinations.map(\.kind))

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.rmNotebookName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            AppIconButton(systemName: "arrow.triangle.2.circlepath",
                          help: "Sync this rule now",
                          spinOnTap: true) { onSyncRule() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? theme.borderFocus : theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpenWindow() }
    }

    private var secondaryLine: String {
        let count = rule.destinations.count
        let destinationsLabel = "\(count) destination\(count == 1 ? "" : "s")"
        if isActive { return "Syncing…" }
        if !rule.enabled { return "Off · \(destinationsLabel)" }
        if let lastRun = rule.aggregateLastRunAt {
            let resultLabel = Formatters.syncResultLabel(pageCount: rule.aggregateLastRunPagesSynced)
            return "\(resultLabel) · \(Formatters.relativeLabel(for: lastRun))"
        }
        return destinationsLabel + " · never synced"
    }
}

/// One destination's brand mark with a small count badge when a notebook fans
/// out to more than one destination — compact, instead of a row of icons.
private struct DestinationIconStack: View {
    let kinds: [DestinationKind]
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            primaryIcon
            if kinds.count > 1 {
                countBadge(kinds.count)
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 26, height: 24, alignment: .center)
    }

    @ViewBuilder
    private var primaryIcon: some View {
        if let kind = kinds.first {
            DestinationIcon(kind: kind, size: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
                Image(systemName: "questionmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 22, height: 22)
        }
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.primaryForeground)
            .padding(.horizontal, count > 9 ? 3 : 0)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(theme.primary))
            .overlay(Capsule().strokeBorder(theme.background, lineWidth: 1.5))
    }
}

// MARK: - Empty state

private struct EmptyRulesState: View {
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.card)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(theme.muted)
            }
            .frame(width: 56, height: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )

            VStack(spacing: 4) {
                Text("No Rules Yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Pair your reMarkable, connect Notion, then pick a notebook to sync.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            AppPrimaryButton(title: "Open Sync Bar", systemImage: "macwindow", action: onOpen)
                .padding(.top, 4)
        }
    }
}
