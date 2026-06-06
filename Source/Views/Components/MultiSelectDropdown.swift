//
//  MultiSelectDropdown.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A multi-select sibling of CustomDropdown: the whole bar is the control, it
//  expands an inline styled list, and each row toggles on tap (with a check) so
//  several can be picked at once. Used for the two-way sync's status filter.
//

import SwiftUI

struct MultiSelectOption: Identifiable {
    let id: String
    let title: String
    let icon: AnyView
}

struct MultiSelectDropdown: View {
    let options: [MultiSelectOption]
    let selected: Set<String>
    var placeholder: String
    let onToggle: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var isOpen = false

    private var summary: String {
        let chosen = options.filter { selected.contains($0.id) }.map(\.title)
        if chosen.isEmpty { return placeholder }
        if chosen.count <= 2 { return chosen.joined(separator: ", ") }
        return "\(chosen.count) selected"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                guard !options.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.16)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(summary)
                        .font(.system(size: 14, weight: selected.isEmpty ? .medium : .semibold))
                        .foregroundStyle(selected.isEmpty ? theme.muted : theme.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Rectangle().fill(theme.divider).frame(height: 1)
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button { onToggle(option.id) } label: {
                            HStack(spacing: 10) {
                                option.icon
                                Text(option.title)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(theme.foregroundSoft).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: selected.contains(option.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected.contains(option.id) ? theme.primary : theme.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
