//
//  MenuBarPopover.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct MenuBarPopoverActions {
    var syncNow: (String?, String?) -> Void   // ruleId, bindingId
    var syncTask: (TaskSync) -> Void           // run one two-way sync
    var openMainWindow: () -> Void
    var openSettings: () -> Void
    var openNotionUrl: (URL) -> Void
    var togglePause: () -> Void
    var uploadFiles: () -> Void
    var quit: () -> Void
}

struct MenuBarPopover: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject var taskCoordinator: TaskSyncCoordinator
    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var entitlement = EntitlementManager.shared

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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Sync Bar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                    // "Paused" is already the headline unless a manual run is going.
                    if overview.isPaused && overview.tone == .active { PausedPill() }
                }
                Text(overview.headline)
                    .font(.system(size: 10.5, weight: overview.tone == .neutral ? .regular : .semibold))
                    .foregroundStyle(overview.tone == .neutral ? theme.muted : theme.color(for: overview.tone))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if ledger.remarkableAccount != nil {
                AppIconButton(systemName: "arrow.up.doc",
                              help: "Upload PDF or EPUB to reMarkable") { actions.uploadFiles() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.surface)
    }

    private var overview: SyncOverview {
        SyncOverview.current(coordinator: coordinator, taskCoordinator: taskCoordinator)
    }

    private var isAnySyncing: Bool { coordinator.isSyncing || taskCoordinator.isSyncing }

    private func isRunning(_ flow: SyncFlow) -> Bool {
        guard coordinator.isSyncing else { return false }
        if let bindingId = coordinator.activeBindingId { return bindingId == flow.binding.id }
        return coordinator.activeRuleId == flow.ruleId
    }

    private func isPaidInactive(_ flow: SyncFlow) -> Bool {
        guard let feature = flow.rule.sourceKind.paidFeature else { return false }
        return !entitlement.isEntitled(to: feature)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        // Cap the dropdown at 10 syncs so it never grows unwieldy; the full list
        // lives in the main window. One-way flows first, then two-way task syncs.
        let flows = Array(ledger.syncFlows.prefix(10))
        let taskSyncs = Array(ledger.taskSyncs.prefix(max(0, 10 - flows.count)))
        if flows.isEmpty && taskSyncs.isEmpty {
            EmptyRulesState(onOpen: actions.openMainWindow)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(flows) { flow in
                    let running = isRunning(flow)
                    let inactive = isPaidInactive(flow)
                    MenuSyncRow(
                        sourceName: flow.folderName,
                        destinationName: flow.kind.label,
                        isTwoWay: false,
                        status: SyncRowStatus.make(
                            isSyncing: running, isEnabled: flow.isEnabled, isPaidInactive: inactive,
                            lastStatus: flow.binding.lastRunStatus, lastRunAt: flow.lastRunAt,
                            lastError: flow.binding.lastRunError, now: Date()),
                        isBusy: running,
                        isBlocked: coordinator.isSyncing,
                        canSync: flow.isEnabled && !inactive,
                        onSyncNow: { actions.syncNow(flow.ruleId, flow.binding.id) },
                        onOpenWindow: actions.openMainWindow
                    )
                }
                ForEach(taskSyncs) { sync in
                    let running = taskCoordinator.isSyncing && taskCoordinator.activeSyncId == sync.id
                    MenuSyncRow(
                        sourceName: sync.remindersListName,
                        destinationName: sync.provider.displayName,
                        isTwoWay: true,
                        status: SyncRowStatus.make(
                            isSyncing: running, isEnabled: sync.enabled, isPaidInactive: false,
                            lastStatus: sync.lastRunStatus, lastRunAt: sync.lastRunAt,
                            lastError: sync.lastRunError, now: Date()),
                        isBusy: running,
                        isBlocked: taskCoordinator.isSyncing,
                        canSync: sync.enabled,
                        onSyncNow: { actions.syncTask(sync) },
                        onOpenWindow: actions.openMainWindow
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
    }

    // MARK: Footer

    private func footer(theme: ThemePalette) -> some View {
        HStack(spacing: 4) {
            SyncNowButton(isBusy: isAnySyncing, help: "Sync all now", bordered: false) {
                actions.syncNow(nil, nil)
            }

            AppIconButton(
                systemName: settings.pauseSyncing ? "play.fill" : "pause.fill",
                help: settings.pauseSyncing ? "Resume syncing" : "Pause syncing",
                tint: settings.pauseSyncing ? .warning : .foreground
            ) { actions.togglePause() }

            AppIconButton(systemName: "macwindow", help: "Open Sync Bar") { actions.openMainWindow() }
            AppIconButton(systemName: "gearshape", help: "Settings (⌘,)") { actions.openSettings() }

            Spacer(minLength: 0)
            AppIconButton(systemName: "power", help: "Quit Sync Bar") { actions.quit() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(theme.surface)
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
                Text("No syncs yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Open Sync Bar to add one.")
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

// MARK: - Menu sync row

/// One row in the menu bar list, for a one-way flow or a two-way task sync.
private struct MenuSyncRow: View {
    let sourceName: String
    let destinationName: String
    let isTwoWay: Bool
    let status: SyncRowStatus
    let isBusy: Bool
    let isBlocked: Bool
    let canSync: Bool
    let onSyncNow: () -> Void
    let onOpenWindow: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(theme.color(for: status.tone)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(sourceName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground).lineLimit(1)
                    Image(systemName: isTwoWay ? "arrow.left.arrow.right" : "arrow.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.tertiary)
                    Text(destinationName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground).lineLimit(1)
                }
                Text(status.detail ?? status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(status.tone == .failure || status.tone == .warning
                                     ? theme.color(for: status.tone) : theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(status.detail ?? "")
            }
            Spacer(minLength: 8)
            if canSync {
                SyncNowButton(isBusy: isBusy, isDisabled: isBlocked, help: "Sync this now",
                              bordered: false, action: onSyncNow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onOpenWindow() }
    }
}
