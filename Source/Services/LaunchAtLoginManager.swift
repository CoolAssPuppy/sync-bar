//
//  LaunchAtLoginManager.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import ServiceManagement
import Combine

/// Bridges the `AppSettings.launchAtStartup` toggle to macOS's
/// SMAppService.mainApp so the app registers/unregisters itself as a login
/// item without requiring a Login Items helper.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool

    private var subscription: AnyCancellable?

    private init() {
        if #available(macOS 13.0, *) {
            self.isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            self.isEnabled = false
        }
        subscription = AppSettings.shared.$launchAtStartup
            .sink { [weak self] desired in self?.apply(desired: desired) }
    }

    func apply(desired: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if desired {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            isEnabled = service.status == .enabled
            Log.app.info("LaunchAtLogin desired=\(desired, privacy: .public) status=\(service.status.rawValue, privacy: .public)")
        } catch {
            Log.app.error("LaunchAtLogin failed: \(String(describing: error), privacy: .public)")
        }
    }
}
