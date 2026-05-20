//
//  AppSettings.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Combine
import SwiftUI

/// User-facing knobs that aren't account or rule data.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Storage keys
    static let launchAtStartupKey       = "settings.launchAtStartup"
    static let syncIntervalSecondsKey   = "settings.syncIntervalSeconds"
    static let ocrProviderKey           = "settings.ocrProvider"
    static let ocrModelKey              = "settings.ocrModel"
    static let notifyOnFailureKey       = "settings.notifyOnFailure"
    static let notifyOnSuccessKey       = "settings.notifyOnSuccess"
    static let openWindowOnLaunchKey    = "settings.openWindowOnLaunch"
    static let pauseSyncingKey          = "settings.pauseSyncing"

    // MARK: Defaults
    @Published var launchAtStartup: Bool {
        didSet { UserDefaults.standard.set(launchAtStartup, forKey: Self.launchAtStartupKey) }
    }

    @Published var syncIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(syncIntervalSeconds, forKey: Self.syncIntervalSecondsKey)
            NotificationCenter.default.post(name: .syncIntervalChanged, object: nil)
        }
    }

    @Published var ocrProvider: OcrProviderChoice {
        didSet { UserDefaults.standard.set(ocrProvider.rawValue, forKey: Self.ocrProviderKey) }
    }

    @Published var ocrModel: String {
        didSet { UserDefaults.standard.set(ocrModel, forKey: Self.ocrModelKey) }
    }

    @Published var notifyOnFailure: Bool {
        didSet { UserDefaults.standard.set(notifyOnFailure, forKey: Self.notifyOnFailureKey) }
    }

    @Published var notifyOnSuccess: Bool {
        didSet { UserDefaults.standard.set(notifyOnSuccess, forKey: Self.notifyOnSuccessKey) }
    }

    @Published var openWindowOnLaunch: Bool {
        didSet { UserDefaults.standard.set(openWindowOnLaunch, forKey: Self.openWindowOnLaunchKey) }
    }

    @Published var pauseSyncing: Bool {
        didSet {
            UserDefaults.standard.set(pauseSyncing, forKey: Self.pauseSyncingKey)
            NotificationCenter.default.post(name: .pauseSyncingChanged, object: nil)
        }
    }

    /// Available sync interval presets. Surface from the Settings picker.
    static let intervalOptions: [(label: String, seconds: Int)] = [
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1_800),
        ("1 hour", 3_600),
        ("4 hours", 14_400),
        ("Manual only", 0)
    ]

    private init() {
        let defaults = UserDefaults.standard

        // Use the registered default before reading, so first-launch matches the spec.
        defaults.register(defaults: [
            Self.launchAtStartupKey: true,
            Self.syncIntervalSecondsKey: 900,
            Self.ocrProviderKey: OcrProviderChoice.vision.rawValue,
            Self.ocrModelKey: "",
            Self.notifyOnFailureKey: true,
            Self.notifyOnSuccessKey: false,
            Self.openWindowOnLaunchKey: false,
            Self.pauseSyncingKey: false
        ])

        self.launchAtStartup = defaults.bool(forKey: Self.launchAtStartupKey)
        self.syncIntervalSeconds = defaults.integer(forKey: Self.syncIntervalSecondsKey)
        let providerRaw = defaults.string(forKey: Self.ocrProviderKey) ?? OcrProviderChoice.vision.rawValue
        self.ocrProvider = OcrProviderChoice(rawValue: providerRaw) ?? .vision
        self.ocrModel = defaults.string(forKey: Self.ocrModelKey) ?? ""
        self.notifyOnFailure = defaults.bool(forKey: Self.notifyOnFailureKey)
        self.notifyOnSuccess = defaults.bool(forKey: Self.notifyOnSuccessKey)
        self.openWindowOnLaunch = defaults.bool(forKey: Self.openWindowOnLaunchKey)
        self.pauseSyncing = defaults.bool(forKey: Self.pauseSyncingKey)
    }

    func resetToDefaults() {
        launchAtStartup = true
        syncIntervalSeconds = 900
        ocrProvider = .vision
        ocrModel = ""
        notifyOnFailure = true
        notifyOnSuccess = false
        openWindowOnLaunch = false
        pauseSyncing = false
    }
}
