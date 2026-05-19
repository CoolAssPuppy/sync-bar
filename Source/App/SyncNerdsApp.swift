//
//  SyncNerdsApp.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

@main
struct SyncNerdsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No main scene; everything is driven by the AppDelegate-owned
        // status item, popover, and main window. The Settings scene
        // shipped by SwiftUI would add a stale empty preferences window
        // we don't want.
        Settings { EmptyView() }
    }
}
