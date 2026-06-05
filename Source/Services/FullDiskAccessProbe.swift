//
//  FullDiskAccessProbe.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import AppKit

/// Detects whether the app can read TCC-protected library files (Safari's
/// bookmarks live under ~/Library/Safari, which requires Full Disk Access).
/// FDA is a user-granted permission, not an entitlement, so all we can do is
/// probe for it and point the user at System Settings.
enum FullDiskAccessProbe {
    /// Safari's bookmarks file — the thing that needs Full Disk Access to read.
    static var safariBookmarksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
    }

    /// True when we can actually read Safari's bookmarks. Opens the file and
    /// reads a byte; a permission failure (no FDA) or a missing file returns
    /// false. Side-effect-free and cheap enough to call from the UI.
    static func hasAccess() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: safariBookmarksURL) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 1)) ?? nil) != nil
    }

    /// Opens System Settings at Privacy & Security → Full Disk Access so the
    /// user can grant access. They must relaunch the app afterward for TCC to
    /// take effect.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
