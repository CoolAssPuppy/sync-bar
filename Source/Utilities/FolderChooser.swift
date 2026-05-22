//
//  FolderChooser.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import AppKit

/// A directory picker, shared by every place that needs the user to choose a
/// local folder (a Markdown destination's default folder, and editing it later).
enum FolderChooser {
    /// Presents a directory-only open panel and returns the chosen folder's
    /// path, or nil if the user cancelled.
    @MainActor
    static func choose(title: String = "Pick a folder for Markdown notes") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
