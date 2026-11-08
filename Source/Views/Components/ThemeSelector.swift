//
//  ThemeSelector.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct ThemeSelector: View {
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @FocusState private var isTriggerFocused: Bool
    @Namespace private var selectionMotion

    private let dotSize: CGFloat = 16
    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.9)

    var body: some View {
        HStack(spacing: 8) {
            Text(store.current.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.muted)
                .fixedSize()

            HStack(spacing: 5) {
                Button {
                    setExpanded(!isExpanded)
                } label: {
                    swatch(for: store.current)
                        .matchedGeometryEffect(id: store.current.id, in: selectionMotion)
                        .overlay {
                            Circle()
                                .strokeBorder(theme.foreground.opacity(0.85), lineWidth: 1.5)
                                .padding(-3)
                        }
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .focused($isTriggerFocused)
                .help(isExpanded ? "Close theme choices" : "Choose theme")
                .accessibilityLabel("Theme: \(store.current.label)")
                .accessibilityHint(isExpanded ? "Close theme choices" : "Show theme choices")

                if isExpanded {
                    ForEach(AppTheme.allCases.filter { $0 != store.current }) { option in
                        Button {
                            withAnimation(motion) {
                                store.current = option
                                isExpanded = false
                            }
                            isTriggerFocused = true
                        } label: {
                            swatch(for: option)
                                .matchedGeometryEffect(id: option.id, in: selectionMotion)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 28)
                        .help(option.label)
                        .accessibilityLabel("Use \(option.label) theme")
                    }
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
        .animation(motion, value: isExpanded)
        .onHover { setExpanded($0) }
        .onExitCommand { setExpanded(false) }
    }

    private var motion: Animation? { reduceMotion ? nil : spring }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        withAnimation(motion) { isExpanded = expanded }
    }

    @ViewBuilder
    private func swatch(for option: AppTheme) -> some View {
        if option == .system {
            ZStack {
                Circle().fill(Color.white)
                Circle()
                    .fill(Color.black)
                    .mask(
                        Rectangle()
                            .frame(width: dotSize, height: dotSize)
                            .offset(x: dotSize / 2)
                    )
            }
            .frame(width: dotSize, height: dotSize)
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [option.palette.primary, option.palette.primaryDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: dotSize, height: dotSize)
        }
    }
}
