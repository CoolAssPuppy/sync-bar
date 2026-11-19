//
//  PickerLoadError.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// One line under a picker whose options failed to load, with Retry.
struct PickerLoadError: View {
    let message: String
    let onRetry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.destructive)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(theme.destructive)
                .lineLimit(2)
            Button("Retry", action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.primary)
        }
        .padding(.horizontal, 4)
    }
}
