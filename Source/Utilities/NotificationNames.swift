//
//  NotificationNames.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

extension Notification.Name {
    // Ledger changes
    static let remarkableAccountChanged = Notification.Name("syncbar.remarkableAccountChanged")
    static let notionWorkspacesChanged  = Notification.Name("syncbar.notionWorkspacesChanged")
    static let destinationsChanged      = Notification.Name("syncbar.destinationsChanged")
    static let rulesChanged             = Notification.Name("syncbar.rulesChanged")
    static let eventsChanged            = Notification.Name("syncbar.eventsChanged")
    static let foldersChanged         = Notification.Name("syncbar.foldersChanged")
    static let taskSyncsChanged         = Notification.Name("syncbar.taskSyncsChanged")

    // Sync runtime
    static let syncStarted              = Notification.Name("syncbar.syncStarted")
    static let syncFinished             = Notification.Name("syncbar.syncFinished")
    static let syncIntervalChanged      = Notification.Name("syncbar.syncIntervalChanged")
    static let pauseSyncingChanged      = Notification.Name("syncbar.pauseSyncingChanged")

    // Window / drawer actions
    static let openMainWindow           = Notification.Name("syncbar.openMainWindow")
    static let openSettingsDrawer       = Notification.Name("syncbar.openSettingsDrawer")
    static let openSyncLog              = Notification.Name("syncbar.openSyncLog")
    static let openOnboarding           = Notification.Name("syncbar.openOnboarding")
    static let openAddNotionWorkspace   = Notification.Name("syncbar.openAddNotion")
    static let openPairRemarkable       = Notification.Name("syncbar.openPairRemarkable")
    static let notebookSelectionChanged = Notification.Name("syncbar.notebookSelected")
    static let selectRemarkableView     = Notification.Name("syncbar.selectRemarkableView")
    static let remarkableUploadFinished = Notification.Name("syncbar.remarkableUploadFinished")
}
