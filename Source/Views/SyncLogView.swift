//
//  SyncLogView.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

struct SyncLogView: View {
    @Binding var search: String
    @Binding var selectedEventType: String

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if filteredEvents.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(filteredEvents) { event in
                        EventRow(event: event)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
        .background(theme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.muted)
            Text("No Events Yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text("Once Sync Bar starts syncing, every rule run, page write, and failure shows up here.")
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
    @State private var isExpanded = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
            if isExpanded {
                Divider().background(theme.border).padding(.top, 8).padding(.bottom, 6)
                expandedDetails
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            if isSyncRow {
                SourceMark(size: 20)
                Text(sourceFolderName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(2)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
                destinationIcon
                Text(destinationName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.foregroundSoft)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            } else {
                Image(systemName: badgeIcon(for: event.eventType))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(badgeColor(for: statusKind))
                    .frame(width: 16).help(statusHelp)
                Text(event.ruleName ?? event.eventType.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(2)
            }

            Spacer(minLength: 8)

            Circle().fill(badgeColor(for: statusKind)).frame(width: 6, height: 6).help(statusHelp)

            Text(Formatters.logRowLabel(for: event.occurredAt))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiary)
                .monospacedDigit()
                .frame(minWidth: 58, alignment: .trailing)

            Text(durationLabel)
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiary)
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiary)
                .frame(width: 10)
                .help(isExpanded ? "Hide details" : "Show details")
        }
    }

    /// Sync-run events carry "folder → destination" in their name; reuse the
    /// real source + destination icons for those rows.
    private var isSyncRow: Bool { (event.ruleName ?? "").contains(" → ") }

    private var sourceFolderName: String {
        guard let name = event.ruleName, let r = name.range(of: " → ") else { return event.rmNotebookName ?? "" }
        return String(name[..<r.lowerBound])
    }

    private var destinationName: String {
        guard let name = event.ruleName, let r = name.range(of: " → ") else { return "" }
        return String(name[r.upperBound...])
    }

    private var destinationKind: DestinationKind? {
        guard let ruleId = event.ruleId, let rule = Ledger.shared.rules.first(where: { $0.id == ruleId }) else { return nil }
        if let exact = rule.destinations.first(where: { $0.configuration.summary == destinationName }) { return exact.kind }
        return rule.destinations.count == 1 ? rule.destinations.first?.kind : nil
    }

    @ViewBuilder private var destinationIcon: some View {
        if let kind = destinationKind {
            DestinationIcon(kind: kind, size: 20)
        } else {
            Image(systemName: "square.dashed").font(.system(size: 11)).foregroundStyle(theme.muted).frame(width: 20)
        }
    }

    @ViewBuilder
    private var filenameView: some View {
        if let name = event.rmNotebookName, !name.isEmpty {
            if let url = event.notionPageUrl.flatMap(URL.init(string:)) {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    HStack(spacing: 3) {
                        Text(name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .help(url.absoluteString)
            } else {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var durationLabel: String {
        guard let ms = event.durationMs else { return "" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detailFields, id: \.label) { field in
                HStack(alignment: .top, spacing: 8) {
                    Text(field.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.tertiary)
                        .frame(width: 76, alignment: .leading)
                    Text(field.value)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button(action: copyAll) {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        Text(didCopy ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .help("Copy event details")
            }
        }
    }

    private struct DetailField { let label: String; let value: String }

    private var detailFields: [DetailField] {
        var out: [DetailField] = [DetailField(label: "Type", value: event.eventType.label)]
        if let value = event.ruleName, !value.isEmpty { out.append(DetailField(label: "Rule", value: value)) }
        if let value = event.rmNotebookName, !value.isEmpty { out.append(DetailField(label: "Notebook", value: value)) }
        if let value = event.rmPageId, !value.isEmpty { out.append(DetailField(label: "Page", value: value)) }
        if let value = event.ocrProvider, !value.isEmpty { out.append(DetailField(label: "Provider", value: value)) }
        if let value = event.durationMs { out.append(DetailField(label: "Duration", value: "\(value) ms")) }
        out.append(DetailField(label: "When", value: event.occurredAt.formatted(date: .abbreviated, time: .standard)))
        if let value = event.notionPageUrl, !value.isEmpty { out.append(DetailField(label: "URL", value: value)) }
        if let value = event.errorMessage, !value.isEmpty { out.append(DetailField(label: "Error", value: value)) }
        return out
    }

    private func copyAll() {
        let text = detailFields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
    }

    private var statusKind: StatusPill.Kind {
        switch event.eventType {
        case .pageSynced:       return .success
        case .pageFailed:       return .destructive
        case .ruleRunStarted:   return .info
        case .ruleRunCompleted: return .info
        case .tokenRefreshed:   return .neutral
        case .orphanDetected:   return .warning
        case .cycleSkipped:     return .neutral
        }
    }

    /// Plain-language tooltip for the leading status glyph.
    private var statusHelp: String {
        switch event.eventType {
        case .pageSynced:       return "Note synced successfully"
        case .pageFailed:       return "Sync failed"
        case .ruleRunStarted:   return "Sync run started"
        case .ruleRunCompleted: return "Sync run completed"
        case .tokenRefreshed:   return "Auth token refreshed"
        case .orphanDetected:   return "Orphaned item detected"
        case .cycleSkipped:     return "Sync ran but found nothing to do"
        }
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
        case .cycleSkipped:     return "minus.circle"
        }
    }
}
