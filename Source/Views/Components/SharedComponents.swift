//
//  SharedComponents.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

// MARK: - Card

struct AppCard<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.bottom, AppSpacing.lg)

            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }
}

extension AppCard where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

extension AppCard {
    init(_ title: LocalizedStringKey,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: trailing, content: content)
    }
}

// MARK: - Settings row

struct AppSettingRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey?
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.theme) private var theme

    init(_ title: LocalizedStringKey,
         description: LocalizedStringKey? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AppSpacing.md)
            trailing()
        }
    }
}

// MARK: - Row divider

struct AppRowDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.dividerSubtle)
            .frame(height: 1)
    }
}

// MARK: - Button tints

enum AppButtonTint {
    case foreground, primary, destructive
}

struct AppSecondaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var tint: AppButtonTint = .foreground
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tintColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(isHovered ? theme.cardElevated : theme.cardInset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var tintColor: Color {
        switch tint {
        case .foreground:  return theme.foreground
        case .primary:     return theme.primary
        case .destructive: return theme.destructive
        }
    }

    private var borderColor: Color {
        switch tint {
        case .destructive: return theme.destructive.opacity(0.35)
        default:           return theme.borderStrong
        }
    }
}

struct AppPrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isDisabled: Bool = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.primaryForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isDisabled
                                ? [theme.dim, theme.dim]
                                : [theme.primary, theme.primaryDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(theme.primary.opacity(isDisabled ? 0 : 0.4), lineWidth: 1)
            )
            .opacity(isHovered && !isDisabled ? 0.92 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(isDisabled)
    }
}

struct AppIconButton: View {
    let systemName: String
    var help: LocalizedStringKey = ""
    var tint: AppButtonTint = .foreground
    var spinOnTap: Bool = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isSpinning = false

    var body: some View {
        Button(action: handleTap) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? theme.foreground : restingColor)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(isSpinning ? .easeInOut(duration: 0.6) : .default, value: isSpinning)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(isHovered ? theme.cardElevated : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }

    private var restingColor: Color {
        switch tint {
        case .foreground:  return theme.muted
        case .primary:     return theme.primary
        case .destructive: return theme.destructive
        }
    }

    private func handleTap() {
        if spinOnTap {
            isSpinning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isSpinning = false
            }
        }
        action()
    }
}

// MARK: - Brand mark

struct BrandMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.primary, theme.primaryDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Theme strip (used in popover footer)

struct ThemeStrip: View {
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    private static let bouncy: Animation = .spring(response: 0.35, dampingFraction: 0.6)
    private static let dotSize: CGFloat = 10

    var body: some View {
        HStack(spacing: isExpanded ? 6 : 0) {
            ForEach(AppTheme.allCases) { option in
                let palette = option.palette
                let isActive = store.current == option
                let show = isExpanded || isActive

                Button {
                    withAnimation(Self.bouncy) {
                        store.current = option
                        isExpanded = false
                    }
                } label: {
                    ZStack {
                        dotFill(for: option, palette: palette)
                        if isActive {
                            Circle()
                                .stroke(theme.foreground.opacity(0.9), lineWidth: 1.5)
                                .padding(-2.5)
                        }
                    }
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .scaleEffect(show ? 1 : 0.01)
                    .opacity(show ? 1 : 0)
                }
                .buttonStyle(.plain)
                .frame(width: show ? Self.dotSize : 0)
                .clipped()
                .help(option.label)
            }
        }
        .padding(.horizontal, isExpanded ? 9 : 6)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.card))
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        .animation(Self.bouncy, value: isExpanded)
        .onHover { hovering in
            withAnimation(Self.bouncy) {
                isExpanded = hovering
            }
        }
    }

    @ViewBuilder
    private func dotFill(for option: AppTheme, palette: ThemePalette) -> some View {
        if option == .system {
            ZStack {
                Circle().fill(Color.white)
                Circle()
                    .fill(Color.black)
                    .mask(
                        Rectangle()
                            .frame(width: Self.dotSize, height: Self.dotSize)
                            .offset(x: Self.dotSize / 2)
                    )
            }
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [palette.primary, palette.primaryDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    enum Kind {
        case success, warning, destructive, neutral, info
    }

    let label: String
    let kind: Kind

    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
    }

    private var fg: Color {
        switch kind {
        case .success:     return theme.success
        case .warning:     return theme.warning
        case .destructive: return theme.destructive
        case .neutral:     return theme.muted
        case .info:        return theme.primary
        }
    }

    private var bg: Color {
        switch kind {
        case .success:     return theme.success.opacity(0.12)
        case .warning:     return theme.warning.opacity(0.12)
        case .destructive: return theme.destructive.opacity(0.12)
        case .neutral:     return theme.cardElevated
        case .info:        return theme.primary.opacity(0.12)
        }
    }

    private var stroke: Color {
        switch kind {
        case .success:     return theme.success.opacity(0.3)
        case .warning:     return theme.warning.opacity(0.3)
        case .destructive: return theme.destructive.opacity(0.3)
        case .neutral:     return theme.border
        case .info:        return theme.primary.opacity(0.3)
        }
    }
}
