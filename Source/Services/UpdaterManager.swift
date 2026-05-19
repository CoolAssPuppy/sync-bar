//
//  UpdaterManager.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Sparkle

/// Wraps the Sparkle updater so the rest of the app can ignore the
/// SPUUpdaterDelegate boilerplate. The feed URL and Ed25519 public key
/// come from Info.plist (SUFeedURL, SUPublicEDKey).
@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    let updaterController: SPUStandardUpdaterController

    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var currentVersion: String

    private init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Triggers a user-initiated update check. Sparkle displays its own
    /// modal UI: "you're up to date" or an upgrade prompt.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
        lastCheckedAt = Date()
    }
}
