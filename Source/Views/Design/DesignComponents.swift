//
//  DesignComponents.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Small building blocks for the redesigned shell. Reuses DestinationIcon for
//  app marks and the theme palette for color. Kept deliberately spare.
//

import SwiftUI

/// The gold folder chip that stands for a reMarkable source folder.
struct FolderGlyph: View {
    var size: CGFloat = 30
    @Environment(\.theme) private var theme

    var body: some View {
        let radius = size * 0.27
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.primary.opacity(0.10))
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(theme.primary)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.22), lineWidth: 1)
        )
    }
}

/// One left-rail navigation item.
struct RailItem: View {
    let icon: String
    let label: String
    var badge: String? = nil
    let isActive: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isActive ? theme.primary : theme.muted)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? theme.primary : theme.foregroundSoft)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? theme.primary.opacity(0.85) : theme.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? theme.primary.opacity(0.10)
                          : (isHovered ? theme.cardElevated.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A small uppercase tracked section label.
struct SectionLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(theme.tertiary)
    }
}

/// The small "→" connector used between a source and a destination.
struct FlowArrow: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.tertiary)
    }
}

/// Colored status dot for a sync's run state.
struct SyncStatusDot: View {
    let status: RuleRunStatus
    let isSyncing: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: isSyncing ? 4 : 0)
    }

    private var color: Color {
        if isSyncing { return theme.primary }
        switch status {
        case .success:  return theme.success
        case .partial:  return theme.warning
        case .error:    return theme.destructive
        case .running:  return theme.primary
        case .neverRun: return theme.tertiary
        }
    }
}

/// A primary gold pill button matching the redesign (distinct from the shared
/// AppPrimaryButton's gradient treatment).
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var filled: Bool = true
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
                }
                Text(title).font(.system(size: 13, weight: filled ? .bold : .semibold))
            }
            .foregroundStyle(filled ? theme.primaryForeground : theme.foregroundSoft)
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(filled ? theme.primary.opacity(isHovered ? 0.92 : 1)
                          : (isHovered ? theme.cardElevated : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(filled ? Color.clear : theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
