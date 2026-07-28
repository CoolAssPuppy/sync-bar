import Foundation

/// Every event Sync Bar sends, named once.
///
/// Naming: `object_action`, snake_case, action in the past tense.
///
/// These were dot-separated (`account.added`) until 2026-07. PostHog treats the
/// dot as an ordinary character, so nothing broke, but the names sorted oddly
/// and matched nothing in the other apps. Events captured before the rename
/// keep their old names in PostHog forever; build an Action spanning both
/// spellings if you need a metric across the cut.
///
/// A typed enum rather than raw strings because a typo in a string literal is a
/// silent second event in PostHog that nobody notices for months.
enum TelemetryEvent: String {
    case appLaunched = "app_launched"
    case destinationConnectFailed = "destination_connect_failed"
    case destinationConnected = "destination_connected"
    case destinationSynced = "destination_synced"
    case menuOpened = "menu_opened"
    case remarkablePairFailed = "remarkable_pair_failed"
    case remarkablePaired = "remarkable_paired"
    case remarkableUploadCompleted = "remarkable_upload_completed"
    case syncCompleted = "sync_completed"
    case taskSyncCompleted = "task_sync_completed"
    case updateInstalled = "update_installed"
    case xSyncUsageReported = "x_sync_usage_reported"
    case xThreadUsageReported = "x_thread_usage_reported"
}
