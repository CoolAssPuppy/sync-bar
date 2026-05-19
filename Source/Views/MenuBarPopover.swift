//
//  MenuBarPopover.swift
//  SyncNerds
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
                Text("SyncNerds")
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
        let visibleRules = ledger.rules.filter { !$0.destinations.isEmpty }
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
                        activeBindingId: coordinator.activeBindingId,
                        onSyncRule: { actions.syncNow(rule.id, nil) },
                        onSyncBinding: { bindingId in actions.syncNow(rule.id, bindingId) },
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

            AppIconButton(systemName: "macwindow", help: "Open SyncNerds") { actions.openMainWindow() }
            AppIconButton(systemName: "gearshape", help: "Settings (⌘,)") { actions.openSettings() }

            Spacer(minLength: 0)
            ThemeStrip()
            Spacer(minLength: 0)

            AppIconButton(systemName: "power", help: "Quit SyncNerds") { actions.quit() }
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
    let activeBindingId: String?
    let onSyncRule: () -> Void
    let onSyncBinding: (String) -> Void
    let onOpenWindow: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.cardElevated)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primary)
                }
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.borderStrong, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.rmNotebookName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.tertiary)
                        Text("\(rule.destinations.count) destination\(rule.destinations.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.muted)
                    }
                }
                Spacer(minLength: 8)
                statusPill

                AppIconButton(systemName: "arrow.triangle.2.circlepath", help: "Sync all destinations now", spinOnTap: true) {
                    onSyncRule()
                }
            }

            lastRunLine

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(rule.destinations) { binding in
                        BindingMiniRow(binding: binding, isActive: activeBindingId == binding.id) {
                            onSyncBinding(binding.id)
                        }
                    }
                }
                .padding(.top, 2)
            }
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
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenWindow() }
    }

    @ViewBuilder
    private var statusPill: some View {
        if !rule.enabled {
            StatusPill(label: "Off", kind: .neutral)
        } else if isActive {
            StatusPill(label: "Running", kind: .info)
        } else {
            switch rule.aggregateLastRunStatus {
            case .success:  StatusPill(label: "Synced", kind: .success)
            case .partial:  StatusPill(label: "Partial", kind: .warning)
            case .error:    StatusPill(label: "Failed", kind: .destructive)
            case .running:  StatusPill(label: "Running", kind: .info)
            case .neverRun: StatusPill(label: "New", kind: .neutral)
            }
        }
    }

    @ViewBuilder
    private var lastRunLine: some View {
        if let lastRun = rule.aggregateLastRunAt {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiary)
                Text("Last run \(Formatters.relativeLabel(for: lastRun))")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.muted)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiary)
                Text(Formatters.syncResultLabel(pageCount: rule.aggregateLastRunPagesSynced))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.foregroundSoft)
            }
        } else {
            Text("Never run")
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiary)
        }
    }
}

private struct BindingMiniRow: View {
    let binding: DestinationBinding
    let isActive: Bool
    let onSync: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: binding.kind.systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.primary)
                .frame(width: 16)
            Text(binding.configuration.summary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let lastRun = binding.lastRunAt {
                Text(Formatters.syncResultLabel(pageCount: binding.lastRunPagesSynced))
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiary)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiary)
                Text(Formatters.relativeLabel(for: lastRun))
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiary)
            } else {
                Text("Never")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiary)
            }
            Button(action: onSync) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.primary.opacity(0.08) : theme.cardInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? theme.primary.opacity(0.3) : theme.border, lineWidth: 1)
        )
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
                Text("No rules yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Pair your reMarkable, connect Notion, then pick a notebook to sync.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            AppPrimaryButton(title: "Open SyncNerds", systemImage: "macwindow", action: onOpen)
                .padding(.top, 4)
        }
    }
}
