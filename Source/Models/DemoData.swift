//
//  DemoData.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Seeds the ledger with a realistic, fully-populated dataset so the whole UI
/// (folders, connected destinations, rules with varied sync status, and a
/// sync-event history) can be explored or screenshotted without a real device
/// or live cloud content. Loaded into the isolated demo store by
/// `Ledger.setDemoMode(true)`; the real data lives in a separate store and is
/// never touched.
@MainActor
enum DemoData {

    // Stable ids so clearing is targeted.
    private static let notionId = "demo-notion"
    private static let linearId = "demo-linear-eng"
    private static let googleId = "demo@strategicnerds.com"
    private static let appleNotesId = "demo-apple-notes"
    private static let markdownId = "demo-markdown"
    private static let ruleIds = (1...5).map { "demo-rule-\($0)" }

    private static let folders: [RmFolder] = [
        RmFolder(id: "nb-journal",  name: "Daily journal",         parentFolder: "Personal", lastModified: ago(hours: 5),  pageCount: 52),
        RmFolder(id: "nb-meetings", name: "Weekly 1:1s",           parentFolder: "Work",     lastModified: ago(hours: 9),  pageCount: 14),
        RmFolder(id: "nb-standup",  name: "Standup notes",         parentFolder: "Work",     lastModified: ago(hours: 26), pageCount: 31),
        RmFolder(id: "nb-research", name: "Customer interviews",   parentFolder: "Work",     lastModified: ago(hours: 72), pageCount: 17),
        RmFolder(id: "nb-book",     name: "Architecture sketches", parentFolder: "Projects", lastModified: ago(hours: 96), pageCount: 13)
    ]

    // MARK: Load

    static func load(into ledger: Ledger = .shared) {
        ledger.setFolders(folders)

        ledger.upsertNotionWorkspace(NotionWorkspace(
            id: notionId, workspaceName: "Strategic Nerds", workspaceIcon: "🪐",
            botId: "demo-bot", connectedAt: ago(days: 9), lastCatalogRefreshAt: ago(hours: 3)))
        ledger.upsertLinearAccount(LinearAccount(
            id: linearId, name: "Engineering", organizationName: "Strategic Nerds", connectedAt: ago(days: 12)))
        ledger.upsertGoogleAccount(GoogleAccount(
            id: googleId, displayName: googleId, connectedAt: ago(days: 4)))
        ledger.upsertAppleNotesTarget(AppleNotesTarget(
            id: appleNotesId, folderName: "Sync Bar", connectedAt: ago(days: 6)))
        ledger.upsertMarkdownTarget(MarkdownTarget(
            id: markdownId, displayName: "Obsidian vault", folderPath: "/Users/you/Notes", connectedAt: ago(days: 8)))

        for rule in rules() { ledger.upsertRule(rule) }
        for event in events() { ledger.appendEvent(event) }
    }

    // MARK: Builders

    private static func rules() -> [SyncRule] {
        [
            rule(id: ruleIds[0], notebookId: "nb-journal", name: "Daily journal", destinations: [
                binding(.notion(NotionDestinationConfig(workspaceId: notionId, destinationId: "db-journal",
                    destinationType: .database, destinationTitle: "Journal")),
                    status: .success, pages: 3, at: ago(hours: 2)),
                binding(.markdownFolder(MarkdownFolderDestinationConfig(folderPath: "/Users/you/Notes",
                    fileNameTemplate: "{notebook}-page-{page_n}", includeFrontmatter: true)),
                    status: .success, pages: 3, at: ago(hours: 2))
            ]),
            rule(id: ruleIds[1], notebookId: "nb-meetings", name: "Weekly 1:1s", destinations: [
                binding(.linear(LinearDestinationConfig(workspaceId: linearId, workspaceName: "Engineering",
                    projectId: nil, projectName: nil, defaultLabel: "from-rm")),
                    status: .partial, pages: 2, at: ago(hours: 26), error: "1 page failed: Linear rate limited us.")
            ]),
            rule(id: ruleIds[2], notebookId: "nb-standup", name: "Standup notes", destinations: [
                binding(.appleNotes(AppleNotesDestinationConfig(folderName: "Sync Bar")),
                    status: .success, pages: 5, at: ago(hours: 5))
            ]),
            rule(id: ruleIds[3], notebookId: "nb-research", name: "Customer interviews", destinations: [
                binding(.googleDocs(GoogleDocsDestinationConfig(accountEmail: googleId, folderId: nil,
                    folderName: "Research", appendMode: .onePerPage)),
                    status: .error, pages: 0, at: ago(days: 3), error: "Google rejected the request. Reconnect the account.")
            ]),
            rule(id: ruleIds[4], notebookId: "nb-book", name: "Architecture sketches", destinations: [
                binding(.markdownFolder(MarkdownFolderDestinationConfig(folderPath: "/Users/you/Notes/Diagrams",
                    fileNameTemplate: "{notebook}-{date}", includeFrontmatter: false)),
                    status: .neverRun, pages: 0, at: nil)
            ])
        ]
    }

    private static func rule(id: String, notebookId: String, name: String, destinations: [DestinationBinding]) -> SyncRule {
        SyncRule(
            id: id, enabled: true, rmNotebookId: notebookId, rmNotebookName: name,
            titleStrategy: .firstLineOfOcr, titleTemplate: nil, pageOrder: .chronological,
            ocrMode: .all, ocrProviderOverride: nil, savePdfAttachment: true,
            createdAt: ago(days: 10), updatedAt: ago(hours: 2), destinations: destinations)
    }

    private static func binding(_ configuration: DestinationConfiguration,
                                status: RuleRunStatus, pages: Int, at: Date?, error: String? = nil) -> DestinationBinding {
        DestinationBinding(
            id: "demo-binding-\(UUID().uuidString.prefix(8))",
            configuration: configuration, createdAt: ago(days: 10),
            lastRunAt: at, lastRunStatus: status, lastRunPagesSynced: pages, lastRunError: error)
    }

    private static func events() -> [SyncEvent] {
        var out: [SyncEvent] = []
        func event(_ type: SyncEventType, rule: String, notebook: String, page: String? = nil,
                   at: Date, provider: String? = "vision", error: String? = nil, url: String? = nil) {
            out.append(SyncEvent(
                id: "demo-evt-\(out.count)", occurredAt: at, ruleId: "demo", ruleName: rule,
                eventType: type, rmNotebookName: notebook, rmPageId: page, notionPageUrl: url,
                durationMs: type == .ruleRunCompleted ? 1840 : nil, ocrProvider: provider, errorMessage: error))
        }
        // Newest first is handled by appendEvent; emit oldest -> newest.
        event(.ruleRunStarted, rule: "Customer interviews → Research", notebook: "Customer interviews", at: ago(days: 3, minutes: 1))
        event(.pageFailed, rule: "Customer interviews → Research", notebook: "Customer interviews", page: "p-1",
              at: ago(days: 3), error: "Google rejected the request. Reconnect the account.")
        event(.ruleRunStarted, rule: "Standup notes → Sync Bar", notebook: "Standup notes", at: ago(hours: 5, minutes: 1))
        event(.pageSynced, rule: "Standup notes → Sync Bar", notebook: "Standup notes", page: "p-3", at: ago(hours: 5))
        event(.ruleRunCompleted, rule: "Standup notes → Sync Bar", notebook: "Standup notes", at: ago(hours: 5))
        event(.pageSynced, rule: "Daily journal → Journal", notebook: "Daily journal", page: "p-52",
              at: ago(hours: 2), url: "https://www.notion.so/demo")
        event(.ruleRunCompleted, rule: "Daily journal → Journal", notebook: "Daily journal", at: ago(hours: 2))
        return out
    }

    // MARK: Dates

    private static func ago(days: Int = 0, hours: Int = 0, minutes: Int = 0) -> Date {
        Date().addingTimeInterval(-Double(days * 86_400 + hours * 3_600 + minutes * 60))
    }
}
