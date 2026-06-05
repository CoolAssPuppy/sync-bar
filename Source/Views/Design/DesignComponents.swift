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

/// The reMarkable source mark (today's only source; more to come).
struct SourceMark: View {
    var size: CGFloat = 28
    @Environment(\.theme) private var theme
    var body: some View {
        let radius = size * 0.27
        Image("Remarkable")
            .resizable().interpolation(.high).scaledToFit()
            .padding(size * 0.16)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}

/// One option in a `CustomDropdown`.
struct DropdownOption: Identifiable {
    let id: String
    let icon: AnyView
    let title: String
    var subtitle: String? = nil
}

/// A full-width custom dropdown: the whole bar is the control, with a single
/// chevron on the far right. Clicking expands a styled list inline (not the
/// native macOS menu). Used for the From source and To destination.
struct CustomDropdown: View {
    let options: [DropdownOption]
    let selectedId: String?
    var placeholder: String
    var placeholderIcon: AnyView
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var isOpen = false
    @State private var hoverId: String?

    private var selected: DropdownOption? { options.first { $0.id == selectedId } }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                guard !options.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.16)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    selected?.icon ?? placeholderIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected?.title ?? placeholder)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(selected == nil ? theme.muted : theme.foreground)
                            .lineLimit(1)
                        if let sub = selected?.subtitle {
                            Text(sub).font(.system(size: 12)).foregroundStyle(theme.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Rectangle().fill(theme.divider).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options) { opt in
                            Button {
                                onSelect(opt.id)
                                withAnimation(.easeOut(duration: 0.16)) { isOpen = false }
                            } label: {
                                HStack(spacing: 12) {
                                    opt.icon
                                    Text(opt.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(theme.foregroundSoft).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if opt.id == selectedId {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.primary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(hoverId == opt.id ? theme.cardElevated : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { hoverId = opt.id } else if hoverId == opt.id { hoverId = nil }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 230)
            }
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(isOpen ? theme.borderStrong : theme.border, lineWidth: 1))
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
