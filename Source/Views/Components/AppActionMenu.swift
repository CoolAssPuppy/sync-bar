//
//  AppActionMenu.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A vertical-ellipsis "more actions" button whose popover is styled to match the
//  app (themed card, hover rows, destructive in red) rather than the stock macOS
//  fly-out menu. Used on the Connections cards.
//

import SwiftUI

struct AppMenuAction: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void
}

struct AppActionMenu: View {
    let actions: [AppMenuAction]
    @Environment(\.theme) private var theme
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "ellipsis.vertical")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.muted)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(actions) { action in
                    AppActionRow(action: action) { isOpen = false }
                }
            }
            .padding(6)
            .frame(minWidth: 190)
            .background(theme.surface)
            .presentationBackground(theme.surface)
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
        }
    }
}

private struct AppActionRow: View {
    let action: AppMenuAction
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button {
            dismiss()
            action.action()
        } label: {
            HStack(spacing: 10) {
                if let systemImage = action.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16)
                        .foregroundStyle(action.isDestructive ? theme.destructive : theme.muted)
                }
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(action.isDestructive ? theme.destructive : theme.foregroundSoft)
                Spacer(minLength: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hover ? (action.isDestructive ? theme.destructive.opacity(0.12) : theme.cardElevated) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
