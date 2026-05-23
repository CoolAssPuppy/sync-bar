//
//  LinearTeamPickerSheet.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// The teams returned by a Linear OAuth connect, wrapped for `.sheet(item:)`.
struct LinearTeamChoices: Identifiable {
    let teams: [LinearAccount]
    let id = UUID()
}

/// After connecting (or reconnecting) Linear, lets the user pick which teams to
/// add as destinations instead of dumping every team. On reconnect, the teams
/// already added are pre-checked; the checked set becomes the teams that exist
/// (checking adds, unchecking removes that team and its syncs).
struct LinearTeamPickerSheet: View {
    let teams: [LinearAccount]
    let preselected: Set<String>
    var onConfirm: (Set<String>) -> Void
    var onCancel: () -> Void

    @State private var selected: Set<String>
    @ObservedObject private var themeStore = ThemeStore.shared

    init(teams: [LinearAccount], preselected: Set<String>,
         onConfirm: @escaping (Set<String>) -> Void, onCancel: @escaping () -> Void) {
        self.teams = teams
        self.preselected = preselected
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selected = State(initialValue: preselected)
    }

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Linear Teams")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                    Text("Only the teams you check are added as destinations.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.foreground)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(theme.card))
                        .overlay(Circle().strokeBorder(theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider().background(theme.divider)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(teams) { team in
                        let isOn = selected.contains(team.id)
                        Button(action: { toggle(team.id, on: !isOn) }) {
                            HStack(spacing: 10) {
                                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14))
                                    .foregroundStyle(isOn ? theme.primary : theme.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(team.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(theme.foreground)
                                    Text(team.organizationName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.card))
                            .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }

            Divider().background(theme.divider)
            HStack {
                Spacer()
                AppSecondaryButton(title: "Cancel", action: onCancel)
                AppPrimaryButton(title: "Save", systemImage: "checkmark") {
                    onConfirm(selected)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.surface)
        }
        .frame(width: 420, height: 480)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func toggle(_ id: String, on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
    }
}
