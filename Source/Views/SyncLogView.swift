//
//  SyncLogView.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct SyncLogView: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var selectedEventType: String = "all"
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if filteredEvents.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(filteredEvents) { event in
                        EventRow(event: event)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
        .background(theme.background)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedEventType) {
                Text("All events").tag("all")
                Text("Page synced").tag(SyncEventType.pageSynced.rawValue)
                Text("Page failed").tag(SyncEventType.pageFailed.rawValue)
                Text("Run completed").tag(SyncEventType.ruleRunCompleted.rawValue)
                Text("Orphans").tag(SyncEventType.orphanDetected.rawValue)
            }
            .labelsHidden()
            .frame(width: 180)

            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.muted)
            Text("No events yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("Once SyncNerds starts syncing, every rule run, page write, and failure shows up here.")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEvents: [SyncEvent] {
        var output = ledger.events
        if selectedEventType != "all" {
            output = output.filter { $0.eventType.rawValue == selectedEventType }
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            output = output.filter { event in
                event.ruleName?.lowercased().contains(trimmed) == true
                || event.rmNotebookName?.lowercased().contains(trimmed) == true
                || event.errorMessage?.lowercased().contains(trimmed) == true
            }
        }
        return output
    }
}

private struct EventRow: View {
    let event: SyncEvent
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            kindBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.ruleName ?? event.eventType.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                    if let provider = event.ocrProvider, !provider.isEmpty {
                        Text(provider)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.cardElevated))
                    }
                    Spacer(minLength: 6)
                    Text(Formatters.logRowLabel(for: event.occurredAt))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiary)
                        .monospacedDigit()
                }

                Text(detailLine)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(2)

                if let url = event.notionPageUrl.flatMap(URL.init(string:)) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                            Text(url.absoluteString)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(theme.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var detailLine: String {
        if let error = event.errorMessage, !error.isEmpty { return error }
        var parts: [String] = []
        if let notebook = event.rmNotebookName, !notebook.isEmpty { parts.append(notebook) }
        if event.eventType == .pageSynced, let pageId = event.rmPageId { parts.append("page \(pageId)") }
        if let duration = event.durationMs { parts.append("\(duration) ms") }
        if parts.isEmpty { return event.eventType.label }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var kindBadge: some View {
        let kind: StatusPill.Kind = {
            switch event.eventType {
            case .pageSynced:       return .success
            case .pageFailed:       return .destructive
            case .ruleRunStarted:   return .info
            case .ruleRunCompleted: return .info
            case .tokenRefreshed:   return .neutral
            case .orphanDetected:   return .warning
            }
        }()
        ZStack {
            Circle().fill(badgeColor(for: kind).opacity(0.18))
            Image(systemName: badgeIcon(for: event.eventType))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(badgeColor(for: kind))
        }
        .frame(width: 28, height: 28)
    }

    private func badgeColor(for kind: StatusPill.Kind) -> Color {
        switch kind {
        case .success:     return theme.success
        case .warning:     return theme.warning
        case .destructive: return theme.destructive
        case .info:        return theme.primary
        case .neutral:     return theme.muted
        }
    }

    private func badgeIcon(for kind: SyncEventType) -> String {
        switch kind {
        case .pageSynced:       return "checkmark"
        case .pageFailed:       return "exclamationmark.triangle"
        case .ruleRunStarted:   return "play.fill"
        case .ruleRunCompleted: return "flag.checkered"
        case .tokenRefreshed:   return "key"
        case .orphanDetected:   return "questionmark"
        }
    }
}
