//
//  SyncStatusViews.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The pieces every screen uses to show sync state: the tone colors, the
//  status chip on each row, the sync button that spins for the whole run, and
//  the paused banner.
//

import SwiftUI

extension ThemePalette {
    func color(for tone: SyncTone) -> Color {
        switch tone {
        case .active:  return primary
        case .success: return success
        case .warning: return warning
        case .failure: return destructive
        case .neutral: return muted
        case .muted:   return tertiary
        }
    }
}

/// A row's status: dot plus label in a tinted capsule.
struct SyncStatusChip: View {
    let status: SyncRowStatus
    var compact: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        let color = theme.color(for: status.tone)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: status.tone == .active ? 4 : 0)
            Text(status.label)
                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 20 : 24)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// The sync button. Spins for as long as its run lasts and is disabled while
/// anything it would collide with is running, so a click is never dropped.
struct SyncNowButton: View {
    let isBusy: Bool
    var isDisabled: Bool = false
    var help: String = "Sync now"
    var bordered: Bool = true
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SpinningSyncGlyph(isSpinning: isBusy)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: bordered ? 30 : 28, height: bordered ? 30 : 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered && isEnabled ? theme.cardElevated : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(bordered ? theme.border : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(isBusy ? "Syncing…" : (isDisabled ? "Another sync is running" : help))
    }

    private var isEnabled: Bool { !isBusy && !isDisabled }

    private var glyphColor: Color {
        if isBusy { return theme.primary }
        if isDisabled { return theme.tertiary.opacity(0.6) }
        return isHovered ? theme.foreground : theme.muted
    }
}

/// The sync arrows, rotating continuously while `isSpinning`.
struct SpinningSyncGlyph: View {
    let isSpinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !isSpinning)) { context in
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(isSpinning ? angle(at: context.date) : 0))
        }
    }

    private func angle(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2) * 360
    }
}

/// A small "Paused" capsule for headers.
struct PausedPill: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
            Text("Paused").font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(theme.warning)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(theme.warning.opacity(0.14)))
        .overlay(Capsule().strokeBorder(theme.warning.opacity(0.3), lineWidth: 1))
    }
}

/// Full-width banner shown at the top of the Syncs screen while paused.
struct PausedBanner: View {
    let onResume: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.warning)
            Text("Syncing is paused")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Spacer()
            PillButton(title: "Resume", systemImage: "play.fill", action: onResume)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(theme.warning.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }
}
