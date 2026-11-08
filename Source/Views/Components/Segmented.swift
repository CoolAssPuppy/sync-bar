//
//  Segmented.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct Segmented<T: Equatable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = selection == opt.0
                Button(action: { selection = opt.0 }) {
                    Text(opt.1)
                        .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? theme.primaryForeground : theme.muted)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? theme.primary : Color.clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.background))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
