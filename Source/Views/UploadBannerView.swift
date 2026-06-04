//
//  UploadBannerView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The result of an upload, peeking down from the top edge of the window (in the
//  accent color on success, red on error), plus the thin bottom progress bar
//  shown while an upload runs. Both read the shared UploadCoordinator.
//

import SwiftUI

struct UploadBannerView: View {
    @ObservedObject private var coordinator = UploadCoordinator.shared
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            if let banner = coordinator.banner {
                bannerBar(for: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.26), value: coordinator.banner)
    }

    private func bannerBar(for banner: UploadBanner) -> some View {
        let isError = banner.kind == .error
        let tint = isError ? theme.destructive : theme.primary
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(banner.message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(theme.surface)
        .clipShape(bannerShape)
        .overlay(bannerShape.strokeBorder(tint.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var bannerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 14,
                               bottomTrailing: 14, topTrailing: 0),
            style: .continuous
        )
    }
}

/// A 2.5pt accent-colored bar pinned to the bottom edge of the window while an
/// upload is in flight.
struct UploadProgressBar: View {
    let progress: Double
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.primary.opacity(0.15))
                Rectangle().fill(theme.primary)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 2.5)
        .animation(.easeOut(duration: 0.2), value: progress)
    }
}
