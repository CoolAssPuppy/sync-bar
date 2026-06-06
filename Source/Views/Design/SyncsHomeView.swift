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

struct SyncsHomeView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject var taskCoordinator: TaskSyncCoordinator
    var onNew: () -> Void
    var onEdit: (SyncFlow) -> Void
    var onEditTask: (TaskSync) -> Void
    var onRefresh: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme
    @State private var isAddingSource = false

    private var flows: [SyncFlow] { ledger.syncFlows }
    private var taskSyncs: [TaskSync] { ledger.taskSyncs }
    private var hasAnySource: Bool {
        ledger.remarkableAccount != nil || ledger.safariConnected || ledger.remindersConnected
    }
    private var hasAnySync: Bool { !flows.isEmpty || !taskSyncs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if ledger.remarkableNeedsRepair { disconnectedBanner }
            content
        }
        .background(theme.background)
        .sheet(isPresented: $isAddingSource) { AddSourceSheet(isPresented: $isAddingSource) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Syncs")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.foreground)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            AppIconButton(systemName: "arrow.clockwise", help: "Sync all", spinOnTap: true) { syncAll() }
            PillButton(title: "New sync", systemImage: "plus") { onNew() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private func syncAll() {
        coordinator.syncNow()
        taskCoordinator.syncAll()
    }

    private var subtitle: String {
        let count = flows.count + taskSyncs.count
        if count == 0 { return hasAnySource ? "No syncs yet" : "Add a source to begin" }
        let last = (flows.compactMap(\.lastRunAt) + taskSyncs.compactMap(\.lastRunAt)).max()
        let active = "\(count) sync\(count == 1 ? "" : "s")"
        if coordinator.isSyncing || taskCoordinator.isSyncing { return "\(active) · syncing now" }
        if let last { return "\(active) · last run \(Formatters.relativeLabel(for: last))" }
        return "\(active) · not run yet"
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
                LazyVStack(spacing: 10) {
                    ForEach(flows) { flow in
                        SyncRowView(
                            flow: flow,
                            isSyncing: coordinator.isSyncing && coordinator.activeBindingId == flow.binding.id,
                            onTap: { onEdit(flow) },
                            onSyncNow: { coordinator.syncNow(ruleId: flow.ruleId, bindingId: flow.binding.id) }
                        )
                    }
                    ForEach(taskSyncs) { sync in
                        TaskSyncRowView(
                            // Show "Syncing" for the whole run, not just the one row
                            // the coordinator happens to be on, so finished rows in a
                            // batch don't flash "Synced just now" mid-sync.
                            sync: sync,
                            isSyncing: taskCoordinator.isSyncing && sync.enabled,
                            onTap: { onEditTask(sync) },
                            onSyncNow: { Task { await taskCoordinator.run(sync) } }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
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
            VStack(spacing: 6) {
                Text("No syncs yet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("A sync sends one reMarkable folder to one app. Make your first one to start turning notes into text.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
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
            VStack(spacing: 6) {
                Text("Sync Bar syncs your information from Sources to Destinations")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Text("Start by adding a source — your reMarkable, or Safari bookmarks.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
            PillButton(title: "Add your first Source", systemImage: "plus") { isAddingSource = true }
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.destructive)
            Text("reMarkable disconnected — re-pair in Connections to resume syncing.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foregroundSoft)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
        .background(theme.destructive.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }
}

// MARK: - Sync row

private struct SyncRowView: View {
    let flow: SyncFlow
    let isSyncing: Bool
    let onTap: () -> Void
    let onSyncNow: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        SourceIcon(kind: flow.rule.sourceKind, size: 30)
                        Text(flow.folderName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                        FlowArrow()
                        DestinationIcon(kind: flow.kind, size: 26)
                        Text(flow.kind.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                        Text("· \(flow.destinationSummary)")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                    Text(flow.howSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiary)
                        .padding(.leading, 40)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                statusPill
                syncNowButton
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

    private var statusPill: some View {
        HStack(spacing: 6) {
            SyncStatusDot(status: flow.status, isSyncing: isSyncing)
            Text(statusText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var syncNowButton: some View {
        Button(action: onSyncNow) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.muted)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Sync this now")
    }

    private var statusText: String {
        if isSyncing { return "Syncing now…" }
        if !flow.isEnabled { return "Off" }
        switch flow.status {
        case .neverRun: return "Not synced yet"
        case .running:  return "Syncing…"
        case .error:    return "Failed"
        case .partial:  return "Partial"
        case .success:
            if let last = flow.lastRunAt { return "Synced \(Formatters.relativeLabel(for: last))" }
            return "Synced"
        }
    }

    private var statusColor: Color {
        if isSyncing { return theme.primary }
        if !flow.isEnabled { return theme.tertiary }
        switch flow.status {
        case .success:  return theme.success
        case .partial:  return theme.warning
        case .error:    return theme.destructive
        case .running:  return theme.primary
        case .neverRun: return theme.muted
        }
    }
}

// MARK: - Two-way task sync row

private struct TaskSyncRowView: View {
    let sync: TaskSync
    let isSyncing: Bool
    let onTap: () -> Void
    let onSyncNow: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Image("Reminders").resizable().interpolation(.high).scaledToFit().frame(width: 30, height: 30)
                        Text(sync.remindersListName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.foreground).lineLimit(1)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.tertiary)
                        DestinationIcon(kind: .notion, size: 26)
                        Text(sync.provider.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.foreground).lineLimit(1)
                    }
                    Text("Two-way · most recent edit wins")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiary)
                        .padding(.leading, 40)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                statusPill
                syncNowButton
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(isHovered ? theme.cardElevated : theme.card))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(isHovered ? theme.borderStrong : theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }


    private var statusPill: some View {
        HStack(spacing: 6) {
            SyncStatusDot(status: isSyncing ? .running : sync.lastRunStatus, isSyncing: isSyncing)
            Text(statusText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(statusColor).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var syncNowButton: some View {
        Button(action: onSyncNow) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.muted)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Sync this now")
    }

    private var statusText: String {
        if isSyncing { return "Syncing now…" }
        if !sync.enabled { return "Off" }
        switch sync.lastRunStatus {
        case .neverRun: return "Not synced yet"
        case .running:  return "Syncing…"
        case .error:    return "Failed"
        case .partial:  return "Partial"
        case .success:
            if let last = sync.lastRunAt { return "Synced \(Formatters.relativeLabel(for: last))" }
            return "Synced"
        }
    }

    private var statusColor: Color {
        if isSyncing { return theme.primary }
        if !sync.enabled { return theme.tertiary }
        switch sync.lastRunStatus {
        case .success:  return theme.success
        case .partial:  return theme.warning
        case .error:    return theme.destructive
        case .running:  return theme.primary
        case .neverRun: return theme.muted
        }
    }
}
