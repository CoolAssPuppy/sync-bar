//
//  SyncsHomeView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The redesigned home: a flat list of Syncs. Each row is one flow —
//  folder → app · how · status. Creating and editing happen in one editor.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// How the Syncs list is ordered/grouped. Persisted so it survives launches.
enum SyncListOrder: String, CaseIterable, Identifiable {
    case createdDate
    case groupBySource
    case groupByDestination

    var id: String { rawValue }
    var label: String {
        switch self {
        case .createdDate:        return "Sort by created date"
        case .groupBySource:      return "Group by Source"
        case .groupByDestination: return "Group by Destination"
        }
    }
    var isGrouped: Bool { self != .createdDate }
}

/// One row in the list — a one-way flow or a two-way task sync — with the keys
/// the list sorts and groups by, so both kinds order together.
private enum SyncListItem: Identifiable {
    case flow(SyncFlow)
    case task(TaskSync)

    var id: String {
        switch self {
        case .flow(let f): return "flow-\(f.id)"
        case .task(let t): return "task-\(t.id)"
        }
    }
    var createdAt: Date {
        switch self {
        case .flow(let f): return f.binding.createdAt
        case .task(let t): return t.createdAt
        }
    }
    /// The source app (reMarkable, Safari, Notion, Reminders) — the grouping key
    /// for "Group by Source".
    var sourceLabel: String {
        switch self {
        case .flow(let f): return f.rule.sourceKind.label
        case .task:        return "Reminders"
        }
    }
    /// The destination app shown on the row.
    var destinationLabel: String {
        switch self {
        case .flow(let f): return f.kind.label
        case .task: return DestinationKind.notion.label
        }
    }
}

struct SyncsHomeView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject var taskCoordinator: TaskSyncCoordinator
    var onNew: () -> Void
    var onEdit: (SyncFlow) -> Void
    var onEditTask: (TaskSync) -> Void
    /// Opens Activity showing this sync's failures, searched by its source name.
    var onShowFailures: (String) -> Void = { _ in }

    @ObservedObject private var ledger = Ledger.shared
    @ObservedObject private var entitlement = EntitlementManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.theme) private var theme
    @State private var isAddingSource = false
    @State private var reactivateFeature: PaidFeature?
    @State private var isRepairing = false
    @AppStorage("syncs.listOrder") private var orderRaw = SyncListOrder.createdDate.rawValue
    private var order: SyncListOrder { SyncListOrder(rawValue: orderRaw) ?? .createdDate }

    private var flows: [SyncFlow] { ledger.syncFlows }
    private var taskSyncs: [TaskSync] { ledger.taskSyncs }

    /// All syncs as ordered sections. A flat list (one untitled section) for
    /// "created date"; alphabetically-titled sections for the two groupings.
    /// Within every section, newest-created first.
    private var sections: [(title: String?, items: [SyncListItem])] {
        let items = flows.map(SyncListItem.flow) + taskSyncs.map(SyncListItem.task)
        switch order {
        case .createdDate:
            return [(nil, items.sorted { $0.createdAt > $1.createdAt })]
        case .groupBySource:
            return group(items, by: \.sourceLabel)
        case .groupByDestination:
            return group(items, by: \.destinationLabel)
        }
    }

    private func group(_ items: [SyncListItem], by key: (SyncListItem) -> String) -> [(title: String?, items: [SyncListItem])] {
        Dictionary(grouping: items, by: key)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (title: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }
    private var hasAnySource: Bool { ledger.hasAnySource }
    private var hasAnySync: Bool { !flows.isEmpty || !taskSyncs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if ledger.isDemoMode { demoBanner }
            if settings.pauseSyncing { PausedBanner { settings.pauseSyncing = false } }
            if ledger.remarkableNeedsRepair { disconnectedBanner }
            content
        }
        .background(theme.background)
        .sheet(isPresented: $isAddingSource) { AddSourceSheet(isPresented: $isAddingSource) }
        .sheet(isPresented: $isRepairing) {
            RemarkablePairPanel(title: "Re-pair your reMarkable", onClose: { isRepairing = false })
        }
        .sheet(item: $reactivateFeature) { feature in
            // Already consented when the source was added, so reactivation only
            // needs payment — no consent checkbox.
            TwitterPaywallSheet(feature: feature, requireConsent: false,
                                onContinue: { reactivateFeature = nil },
                                onClose: { reactivateFeature = nil })
        }
    }

    /// A paid sync whose subscription has lapsed (or was never active): its config
    /// is preserved but it won't run, so the row reads inactive and tapping it
    /// opens the reactivate dialog instead of the editor.
    private func paidInactiveFeature(for flow: SyncFlow) -> PaidFeature? {
        guard let feature = flow.rule.sourceKind.paidFeature,
              !entitlement.isEntitled(to: feature) else { return nil }
        return feature
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Syncs")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.foreground)
                subtitle.font(.system(size: 13))
            }
            Spacer()
            if hasAnySync {
                sortMenu
                SyncNowButton(isBusy: isAnySyncing, help: "Sync all") { coordinator.syncAll() }
            }
            PillButton(title: "New sync", systemImage: "plus") { onNew() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    /// Sort/group control: an icon-only button; the menu lists each ordering with
    /// its own icon beside the text, the current one ticked.
    private var sortMenu: some View {
        Menu {
            Picker("Order", selection: $orderRaw) {
                ForEach(SyncListOrder.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foregroundSoft)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort or group the syncs")
    }

    private var isAnySyncing: Bool { coordinator.isSyncing || taskCoordinator.isSyncing }

    /// The paused banner already says "paused", so the subtitle reports the
    /// rest of the state.
    private var overview: SyncOverview {
        SyncOverview.current(coordinator: coordinator, taskCoordinator: taskCoordinator, ignoringPause: true)
    }

    private var subtitle: Text {
        let count = flows.count + taskSyncs.count
        if count == 0 {
            return Text(hasAnySource ? "No syncs yet" : "Add a source to begin").foregroundColor(theme.muted)
        }
        let headlineColor = overview.tone == .neutral || overview.tone == .active ? theme.muted
            : theme.color(for: overview.tone)
        return Text("\(count) sync\(count == 1 ? "" : "s") · ").foregroundColor(theme.muted)
            + Text(overview.headline).foregroundColor(headlineColor)
    }

    /// Whether this flow is the one running. The rule is marked before its
    /// destination, so a rule with no destination marked yet counts too.
    private func isRunning(_ flow: SyncFlow) -> Bool {
        guard coordinator.isSyncing else { return false }
        if let bindingId = coordinator.activeBindingId { return bindingId == flow.binding.id }
        return coordinator.activeRuleId == flow.ruleId
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !hasAnySource {
            sourcesHero
        } else if !hasAnySync {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sections, id: \.title) { section in
                        if let title = section.title {
                            sectionHeader(title)
                        }
                        ForEach(section.items) { item in
                            row(for: item)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private func row(for item: SyncListItem) -> some View {
        switch item {
        case .flow(let flow):
            let inactiveFeature = paidInactiveFeature(for: flow)
            let running = isRunning(flow)
            SyncListRow(
                source: AnyView(SourceIcon(kind: flow.rule.sourceKind, size: 30)),
                sourceName: flow.folderName,
                isTwoWay: false,
                destination: AnyView(DestinationIcon(kind: flow.kind, size: 26)),
                destinationName: flow.kind.label,
                summary: flow.howSummary,
                status: SyncRowStatus.make(
                    isSyncing: running, isEnabled: flow.isEnabled, isPaidInactive: inactiveFeature != nil,
                    lastStatus: flow.binding.lastRunStatus, lastRunAt: flow.lastRunAt,
                    lastError: flow.binding.lastRunError, now: Date()),
                isBusy: running,
                isBlocked: coordinator.isSyncing,
                canSync: inactiveFeature == nil,
                onTap: {
                    if let inactiveFeature { reactivateFeature = inactiveFeature } else { onEdit(flow) }
                },
                onSyncNow: { coordinator.syncNow(ruleId: flow.ruleId, bindingId: flow.binding.id) },
                onShowFailures: { onShowFailures(flow.folderName) }
            )
        case .task(let sync):
            let running = taskCoordinator.isSyncing && taskCoordinator.activeSyncId == sync.id
            SyncListRow(
                source: AnyView(Image("Reminders").resizable().interpolation(.high).scaledToFit()
                    .frame(width: 30, height: 30)),
                sourceName: sync.remindersListName,
                isTwoWay: true,
                destination: AnyView(DestinationIcon(kind: .notion, size: 26)),
                destinationName: sync.provider.displayName,
                summary: "Two-way · most recent edit wins",
                status: SyncRowStatus.make(
                    isSyncing: running, isEnabled: sync.enabled, isPaidInactive: false,
                    lastStatus: sync.lastRunStatus, lastRunAt: sync.lastRunAt,
                    lastError: sync.lastRunError, now: Date()),
                isBusy: running,
                isBlocked: taskCoordinator.isSyncing,
                canSync: true,
                onTap: { onEditTask(sync) },
                onSyncNow: { Task { await taskCoordinator.run(sync) } },
                onShowFailures: { onShowFailures(sync.remindersListName) }
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(theme.tertiary)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .padding(.leading, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.card)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 92, height: 92)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            Text("No syncs yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.foreground)
            PillButton(title: "Create your first sync", systemImage: "plus") { onNew() }
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourcesHero: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.card)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 92, height: 92)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            Text("Add a source to start syncing")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            PillButton(title: "Add a source", systemImage: "plus") { isAddingSource = true }
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text("Demo mode: sample data, syncing is off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
            Spacer()
            PillButton(title: "Exit demo", filled: false) { ledger.setDemoMode(false) }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(theme.primary.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.destructive)
            Text("reMarkable disconnected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
            Spacer()
            PillButton(title: "Re-pair", filled: false) { isRepairing = true }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
        .background(theme.destructive.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }
}

// MARK: - Sync row

/// One row on the Syncs screen, for a one-way flow or a two-way task sync.
private struct SyncListRow: View {
    let source: AnyView
    let sourceName: String
    let isTwoWay: Bool
    let destination: AnyView
    let destinationName: String
    let summary: String
    let status: SyncRowStatus
    let isBusy: Bool
    let isBlocked: Bool
    let canSync: Bool
    let onTap: () -> Void
    let onSyncNow: () -> Void
    let onShowFailures: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        source
                        Text(sourceName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                        if isTwoWay {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.tertiary)
                        } else {
                            FlowArrow()
                        }
                        destination
                        Text(destinationName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(status.detail ?? summary)
                            .font(.system(size: 12))
                            .foregroundStyle(status.detail == nil ? theme.tertiary : theme.color(for: status.tone))
                            .lineLimit(1)
                            .help(status.detail ?? "")
                        if status.detail != nil {
                            Button("View log", action: onShowFailures)
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.foregroundSoft)
                                .underline()
                        }
                    }
                    .padding(.leading, 40)
                }
                .opacity(canSync ? 1 : 0.55)
                Spacer(minLength: 12)
                SyncStatusChip(status: status)
                if canSync {
                    SyncNowButton(isBusy: isBusy, isDisabled: isBlocked, help: "Sync this now", action: onSyncNow)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(isHovered ? theme.cardElevated : theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .strokeBorder(isHovered ? theme.borderStrong : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
