//
//  SyncCoordinator.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Combine
import UserNotifications

/// Orchestrates a sync cycle. The reMarkable + Notion clients are pluggable;
/// destinations route through `DestinationRouter`. OCR runs through
/// `OcrProviderFactory` so the provider can be swapped per-rule or globally.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastTickAt: Date?
    @Published private(set) var nextTickAt: Date?
    @Published private(set) var activeRuleId: String?
    @Published private(set) var activeBindingId: String?

    private let ledger: Ledger
    private let settings: AppSettings
    private let keychain: KeychainStore
    private let remarkable: RemarkableClient
    private let engine: RulesEngine
    private var timerTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(ledger: Ledger? = nil,
         settings: AppSettings? = nil,
         keychain: KeychainStore = .shared,
         remarkable: RemarkableClient = RemarkableClientFactory.make(),
         engine: RulesEngine = RulesEngine()) {
        self.ledger = ledger ?? Ledger.shared
        self.settings = settings ?? AppSettings.shared
        self.keychain = keychain
        self.remarkable = remarkable
        self.engine = engine

        NotificationCenter.default.publisher(for: .syncIntervalChanged)
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .pauseSyncingChanged)
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &subscriptions)
    }

    func start() {
        restartTimer()
        Task { await refreshFolders() }
    }
    func stop()  { timerTask?.cancel(); timerTask = nil }

    /// Refreshes the folder list and prunes rules whose folder no longer exists.
    /// Gated on a real device token so it never prunes against the mock client's
    /// sample folders. Runs at launch so the menu bar dropdown is clean even
    /// without opening the main window.
    func refreshFolders() async {
        // Demo mode shows ephemeral sample folders/rules; refreshing from the
        // real device would prune them, so skip while it's on.
        guard !ledger.isDemoMode else { return }
        guard keychain.value(for: .remarkableDeviceToken)?.isEmpty == false else { return }
        do {
            let folders = try await remarkable.listFolders()
            guard !folders.isEmpty else { return }
            ledger.setFolders(folders)
            ledger.pruneRules(keepingFolderIds: Set(folders.map(\.id)))
        } catch {
            Log.sync.error("Folder refresh failed: \(Formatters.userMessage(for: error), privacy: .public)")
        }
    }

    /// What kicked off a cycle, attached to the `sync.run` analytics event.
    private enum SyncTrigger: String {
        case manual
        case scheduled
    }

    func syncNow(ruleId: String? = nil, bindingId: String? = nil) {
        guard !isSyncing else { return }
        Task { await runCycle(ruleId: ruleId, bindingId: bindingId, trigger: .manual) }
    }

    /// One scheduled sync pass. Separate from `syncNow` so the timer and tests
    /// share the exact scheduled-trigger path (which stays quiet when idle).
    func scheduledTick() async {
        await runCycle(ruleId: nil, bindingId: nil, trigger: .scheduled)
    }

    /// The documents in a folder, for the rule sheet's "choose notebooks" picker.
    /// Returns an empty list (rather than throwing) so the UI can show its own
    /// empty/failed state without a do/catch at the call site.
    func files(inFolder folderId: String) async -> [RmFile] {
        do {
            return try await remarkable.listFiles(inFolderId: folderId)
        } catch {
            Log.sync.error("Listing notebooks failed: \(Formatters.userMessage(for: error), privacy: .public)")
            return []
        }
    }

    private func restartTimer() {
        timerTask?.cancel()
        guard self.settings.syncIntervalSeconds > 0,
              !self.settings.pauseSyncing else {
            nextTickAt = nil
            return
        }
        nextTickAt = Date().addingTimeInterval(TimeInterval(self.settings.syncIntervalSeconds))
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Re-read on every loop so a settings change picks up on
                // the next tick without restarting the task.
                let seconds = self.settings.syncIntervalSeconds
                guard seconds > 0, !self.settings.pauseSyncing else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self.scheduledTick()
                self.nextTickAt = Date().addingTimeInterval(TimeInterval(seconds))
            }
        }
    }

    private func runCycle(ruleId: String?, bindingId: String?, trigger: SyncTrigger) async {
        guard !ledger.isDemoMode else { return }
        // A manual "Sync now" always explains itself in the visible log; scheduled
        // ticks stay quiet so an idle account doesn't flood the log every interval.
        let explainSkips = (trigger == .manual)

        guard ledger.remarkableAccount != nil else {
            if explainSkips {
                recordSkip(.noAccountPaired)
            } else {
                Log.sync.info("Skipping scheduled cycle: no reMarkable account paired.")
            }
            return
        }
        guard !self.settings.pauseSyncing else {
            if explainSkips { recordSkip(.syncingPaused) }
            return
        }

        let rules = ledger.rules.filter { rule in
            rule.enabled && (ruleId == nil || rule.id == ruleId) && !rule.destinations.isEmpty
        }
        guard !rules.isEmpty else {
            if explainSkips { recordSkip(noWorkReason(forTargetedRuleId: ruleId), ruleId: ruleId) }
            return
        }

        isSyncing = true
        NotificationCenter.default.post(name: .syncStarted, object: nil)
        let cycleStart = Date()

        for rule in rules {
            activeRuleId = rule.id
            await runRule(rule, restrictedToBindingId: bindingId, explainSkips: explainSkips)
        }

        activeRuleId = nil
        activeBindingId = nil
        lastTickAt = Date()
        isSyncing = false
        NotificationCenter.default.post(name: .syncFinished, object: nil)

        Telemetry.capture("sync.run", properties: [
            "trigger": trigger.rawValue,
            "rules": rules.count,
            "duration_ms": Int(Date().timeIntervalSince(cycleStart) * 1_000)
        ])
    }

    private func runRule(_ rule: SyncRule, restrictedToBindingId: String?, explainSkips: Bool) async {
        let folderName = rule.rmNotebookName
        var files: [RmFile] = []
        do {
            files = try await remarkable.listFiles(inFolderId: rule.rmNotebookId)
        } catch {
            recordFailure(rule: rule, binding: nil, message: Formatters.userMessage(for: error))
            return
        }

        let bindings = rule.destinations.filter { binding in
            binding.enabled && (restrictedToBindingId == nil || binding.id == restrictedToBindingId)
        }
        guard !bindings.isEmpty else {
            if explainSkips { recordSkip(.noEnabledDestinations(folder: folderName), ruleId: rule.id) }
            return
        }
        guard !files.isEmpty else {
            if explainSkips { recordSkip(.folderEmpty(folder: folderName), ruleId: rule.id) }
            return
        }

        // Narrow to the documents this rule is scoped to: the whole folder, or a
        // hand-picked set (e.g. "only my journal").
        let scopedFiles = files.filter { rule.includes(fileId: $0.id) }
        guard !scopedFiles.isEmpty else {
            if explainSkips { recordSkip(.selectedNotesMissing(folder: folderName), ruleId: rule.id) }
            return
        }

        // Skip OCR for files that no enabled binding will accept (e.g. a
        // tag-filtered Linear destination that excludes untagged notes) so we
        // never pay the OCR provider for output nothing will consume.
        let neededFiles = scopedFiles.filter { file in bindings.contains { $0.configuration.accepts(fileTags: file.tags) } }
        guard !neededFiles.isEmpty else {
            if explainSkips { recordSkip(.allNotesFilteredOut(folder: folderName), ruleId: rule.id) }
            return
        }

        // OCR each file once (combining all its pages into one transcript),
        // reused across every binding — provider cost shouldn't scale with
        // destination count.
        let ocr = OcrProviderFactory.make(
            provider: rule.ocrProviderOverride ?? self.settings.ocrProvider,
            model: self.settings.ocrModel
        )
        var transcripts: [(file: RmFile, content: NoteContent)] = []
        for file in neededFiles {
            transcripts.append((file, await buildNoteContent(file, using: ocr)))
        }

        for binding in bindings {
            activeBindingId = binding.id
            await runBinding(rule: rule, folderName: folderName, binding: binding, transcripts: transcripts, ocrName: ocr.name)
        }
        activeBindingId = nil
    }

    /// Builds one note-worth of structured content from a file: typed text
    /// parsed straight from each page (exact paragraph styles, no OCR cost) plus
    /// OCR of any handwriting, combined across pages into one ordered block list.
    private func buildNoteContent(_ file: RmFile, using ocr: OcrProvider) async -> NoteContent {
        let pages = (try? await remarkable.listPages(notebookId: file.id)) ?? []
        var blocks: [NoteBlock] = []
        for page in pages {
            let content = (try? await remarkable.pageContent(for: page))
                ?? RemarkablePageContent(imageData: nil, typedText: [])
            let typedBlocks = content.typedText.map(NoteContentBuilder.block(from:))

            // OCR any strokes on the page (handwriting and diagrams).
            var ocrBlocks: [NoteBlock] = []
            if let imageData = content.imageData, !imageData.isEmpty {
                do {
                    let result = try await ocr.transcribe(imageData: imageData)
                    ocrBlocks = NoteContentBuilder.blocks(fromOCRText: result.text)
                    if let mermaid = result.mermaidSource { ocrBlocks.append(.mermaid(mermaid)) }
                } catch {
                    Log.ocr.error("OCR failed for file \(file.id, privacy: .public): \(Formatters.userMessage(for: error), privacy: .public)")
                }
            }

            // Order typed text and handwriting by their position on the page.
            if content.typedTextFirst {
                blocks.append(contentsOf: typedBlocks + ocrBlocks)
            } else {
                blocks.append(contentsOf: ocrBlocks + typedBlocks)
            }
        }
        return NoteContent(blocks: blocks, provider: ocr.name, model: nil)
    }

    private func runBinding(rule: SyncRule, folderName: String, binding: DestinationBinding,
                            transcripts: [(file: RmFile, content: NoteContent)], ocrName: String) async {
        let client = DestinationRouter.client(for: binding.kind)
        ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName, type: .ruleRunStarted))

        // Apply optional per-binding overrides on top of the rule defaults.
        var effectiveRule = rule
        if let titleOverride = binding.titleStrategyOverride { effectiveRule.titleStrategy = titleOverride }
        if let ocrModeOverride = binding.ocrModeOverride { effectiveRule.ocrMode = ocrModeOverride }

        var notesSynced = 0
        var firstError: String?
        let runStart = Date()

        for (file, content) in transcripts where binding.configuration.accepts(fileTags: file.tags) {
            let directive = engine.evaluate(
                rule: effectiveRule, file: file, folderName: folderName,
                ocrText: content.plainText,
                previouslySyncedHash: ledger.syncedHash(bindingId: binding.id, pageId: file.id)
            )
            guard case .create(let title) = directive else { continue }

            let payload = DestinationPayload(
                title: title,
                body: content.markdownBody,
                blocks: content.blocks,
                mermaidSource: content.firstMermaid,
                sourceDate: file.createdAt,
                pdfData: nil,
                ocrProvider: ocrName,
                ruleNotebookName: file.name,
                folderName: folderName,
                pageNumber: 1
            )
            do {
                let existingId = ledger.syncedExternalId(bindingId: binding.id, pageId: file.id)
                let result = try await client.write(payload: payload, configuration: binding.configuration, existingExternalId: existingId)
                notesSynced += 1
                ledger.recordSyncedPage(bindingId: binding.id, pageId: file.id, versionHash: file.versionHash, externalId: result.externalId)
                ledger.appendEvent(makeEvent(
                    rule: rule, binding: binding, folderName: folderName, type: .pageSynced,
                    noteId: file.id, noteName: file.name, url: result.externalURL?.absoluteString,
                    ocrProvider: ocrName, durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)
                ))
            } catch {
                let msg = Formatters.userMessage(for: error)
                if firstError == nil { firstError = msg }
                ledger.appendEvent(makeEvent(
                    rule: rule, binding: binding, folderName: folderName, type: .pageFailed,
                    noteId: file.id, noteName: file.name, ocrProvider: ocrName, errorMessage: msg
                ))
            }
        }

        let status: RuleRunStatus = {
            if firstError != nil { return notesSynced > 0 ? .partial : .error }
            return .success
        }()
        ledger.updateBindingRunResult(
            ruleId: rule.id, bindingId: binding.id,
            status: status, pagesSynced: notesSynced, runAt: Date(),
            error: firstError
        )
        ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName, type: .ruleRunCompleted,
                                     durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)))

        Telemetry.capture("destination.synced", properties: [
            "provider": binding.kind.rawValue,
            "notes_synced": notesSynced,
            "status": status.rawValue
        ])

        if firstError != nil, self.settings.notifyOnFailure {
            postNotification(title: "Sync failed", body: "\(folderName) → \(binding.configuration.summary)")
        } else if firstError == nil, notesSynced > 0, self.settings.notifyOnSuccess {
            postNotification(title: "Sync complete", body: "\(folderName): \(Formatters.syncResultLabel(pageCount: notesSynced))")
        }
    }

    private func makeEvent(rule: SyncRule,
                           binding: DestinationBinding,
                           folderName: String,
                           type: SyncEventType,
                           noteId: String? = nil,
                           noteName: String? = nil,
                           url: String? = nil,
                           ocrProvider: String? = nil,
                           durationMs: Int? = nil,
                           errorMessage: String? = nil) -> SyncEvent {
        SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: rule.id, ruleName: "\(folderName) → \(binding.configuration.summary)",
            eventType: type,
            rmNotebookName: noteName ?? folderName, rmPageId: noteId,
            notionPageUrl: url, durationMs: durationMs,
            ocrProvider: ocrProvider, errorMessage: errorMessage
        )
    }

    /// Why a manual cycle or rule produced no work. The message is what the user
    /// sees in the log, so it names the folder and the fix where it can.
    enum SyncSkipReason {
        case noAccountPaired
        case syncingPaused
        case noConnectedFolders
        case ruleDisabled(folder: String)
        case folderEmpty(folder: String)
        case selectedNotesMissing(folder: String)
        case noEnabledDestinations(folder: String)
        case allNotesFilteredOut(folder: String)

        var message: String {
            switch self {
            case .noAccountPaired:
                return "Nothing to sync: no reMarkable account is paired."
            case .syncingPaused:
                return "Skipped: syncing is paused."
            case .noConnectedFolders:
                return "Nothing to sync: no folders are connected to a destination."
            case .ruleDisabled(let folder):
                return "Skipped: syncing for \(folder) is turned off."
            case .folderEmpty(let folder):
                return "Nothing to sync: \(folder) has no notebooks."
            case .selectedNotesMissing(let folder):
                return "Nothing to sync: the selected notebooks in \(folder) weren't found."
            case .noEnabledDestinations(let folder):
                return "Nothing to sync: \(folder) has no enabled destinations."
            case .allNotesFilteredOut(let folder):
                return "Nothing to sync: every notebook in \(folder) was excluded by a destination's tag filter."
            }
        }

        /// The reMarkable folder this skip concerns, when it is rule-specific.
        var folderName: String? {
            switch self {
            case .ruleDisabled(let folder),
                 .folderEmpty(let folder),
                 .selectedNotesMissing(let folder),
                 .noEnabledDestinations(let folder),
                 .allNotesFilteredOut(let folder):
                return folder
            case .noAccountPaired, .syncingPaused, .noConnectedFolders:
                return nil
            }
        }
    }

    /// Picks the most accurate "nothing happened" reason when the cycle's rule
    /// filter came up empty. For a targeted manual sync (`ruleId` set) the rule
    /// may exist but be disabled or have no destinations, which is more useful to
    /// say than the generic "no folders are connected".
    private func noWorkReason(forTargetedRuleId ruleId: String?) -> SyncSkipReason {
        guard let ruleId, let rule = ledger.rules.first(where: { $0.id == ruleId }) else {
            return .noConnectedFolders
        }
        if rule.destinations.isEmpty { return .noEnabledDestinations(folder: rule.rmNotebookName) }
        if !rule.enabled { return .ruleDisabled(folder: rule.rmNotebookName) }
        return .noConnectedFolders
    }

    /// Writes a visible "Nothing to sync" event explaining why a manual cycle did
    /// no work, so "Sync now" is never a silent no-op. The folder name stays out
    /// of the system log (it is the user's content); the in-app event carries it.
    private func recordSkip(_ reason: SyncSkipReason, ruleId: String? = nil) {
        Log.sync.info("Cycle skipped: \(reason.message, privacy: .private)")
        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: ruleId, ruleName: reason.message,
            eventType: .cycleSkipped,
            rmNotebookName: reason.folderName, rmPageId: nil,
            notionPageUrl: nil, durationMs: nil,
            ocrProvider: nil, errorMessage: nil
        ))
    }

    private func recordFailure(rule: SyncRule, binding: DestinationBinding?, message: String) {
        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: rule.id, ruleName: binding.map { ruleHeader(rule, binding: $0) } ?? rule.rmNotebookName,
            eventType: .pageFailed,
            rmNotebookName: rule.rmNotebookName, rmPageId: nil,
            notionPageUrl: nil, durationMs: nil,
            ocrProvider: nil, errorMessage: message
        ))
    }

    private func ruleHeader(_ rule: SyncRule, binding: DestinationBinding) -> String {
        "\(rule.rmNotebookName) → \(binding.configuration.summary)"
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
