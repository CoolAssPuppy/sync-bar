//
//  FolderPickerSheet.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Picks a reMarkable folder to route to a destination (the destination-first
/// connect flow). The source-first flow starts from the folder list instead.
struct FolderPickerSheet: View {
    let folders: [RmFolder]
    var onPick: (RmFolder) -> Void
    var onCancel: () -> Void

    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        let theme = themeStore.palette
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a Folder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                    Text("Pick the reMarkable folder to sync to this destination.")
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

            if folders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(theme.muted)
                    Text("No folders found on your reMarkable.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(folders) { folder in
                            Button(action: { onPick(folder) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill").foregroundStyle(theme.primary)
                                    Text(folder.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.foreground)
                                    Spacer()
                                    Text("\(folder.pageCount) notebook\(folder.pageCount == 1 ? "" : "s")")
                                        .font(.system(size: 10)).foregroundStyle(theme.muted)
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
            }
        }
        .frame(width: 420, height: 460)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
