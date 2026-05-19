//
//  NotificationNames.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

extension Notification.Name {
    // Ledger changes
    static let remarkableAccountChanged = Notification.Name("syncnerds.remarkableAccountChanged")
    static let notionWorkspacesChanged  = Notification.Name("syncnerds.notionWorkspacesChanged")
    static let destinationsChanged      = Notification.Name("syncnerds.destinationsChanged")
    static let rulesChanged             = Notification.Name("syncnerds.rulesChanged")
    static let eventsChanged            = Notification.Name("syncnerds.eventsChanged")
    static let notebooksChanged         = Notification.Name("syncnerds.notebooksChanged")

    // Sync runtime
    static let syncStarted              = Notification.Name("syncnerds.syncStarted")
    static let syncFinished             = Notification.Name("syncnerds.syncFinished")
    static let syncIntervalChanged      = Notification.Name("syncnerds.syncIntervalChanged")
    static let pauseSyncingChanged      = Notification.Name("syncnerds.pauseSyncingChanged")

    // Window / drawer actions
    static let openMainWindow           = Notification.Name("syncnerds.openMainWindow")
    static let openSettingsDrawer       = Notification.Name("syncnerds.openSettingsDrawer")
    static let openSyncLog              = Notification.Name("syncnerds.openSyncLog")
    static let openOnboarding           = Notification.Name("syncnerds.openOnboarding")
    static let openAddNotionWorkspace   = Notification.Name("syncnerds.openAddNotion")
    static let openPairRemarkable       = Notification.Name("syncnerds.openPairRemarkable")
    static let notebookSelectionChanged = Notification.Name("syncnerds.notebookSelected")
}
