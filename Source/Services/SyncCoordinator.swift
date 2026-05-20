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
        guard keychain.value(for: .remarkableDeviceToken)?.isEmpty == false else { return }
        do {
            let folders = try await remarkable.listNotebooks()
            guard !folders.isEmpty else { return }
            ledger.setNotebooks(folders)
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
                await self.runCycle(ruleId: nil, bindingId: nil, trigger: .scheduled)
                self.nextTickAt = Date().addingTimeInterval(TimeInterval(seconds))
            }
        }
    }

    private func runCycle(ruleId: String?, bindingId: String?, trigger: SyncTrigger) async {
        guard ledger.remarkableAccount != nil else {
            Log.sync.info("Skipping cycle: no reMarkable account paired.")
            return
        }
        guard !self.settings.pauseSyncing else { return }

        let rules = ledger.rules.filter { rule in
            rule.enabled && (ruleId == nil || rule.id == ruleId) && !rule.destinations.isEmpty
        }
        guard !rules.isEmpty else { return }

        isSyncing = true
        NotificationCenter.default.post(name: .syncStarted, object: nil)
        let cycleStart = Date()

        for rule in rules {
            activeRuleId = rule.id
            await runRule(rule, restrictedToBindingId: bindingId)
        }

        activeRuleId = nil
        activeBindingId = nil
        lastTickAt = Date()
        isSyncing = false
        NotificationCenter.default.post(name: .syncFinished, object: nil)

        Telemetry.capture("sync.run", properties: [
            "trigger": trigger.rawValue,
            "rules": rules.count,
            "duration_ms": Int(Date().timeIntervalSince(cycleStart) * 1_000),
        ])
    }

    private func runRule(_ rule: SyncRule, restrictedToBindingId: String?) async {
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
        guard !bindings.isEmpty, !files.isEmpty else { return }

        // OCR each file once (combining all its pages into one transcript),
        // reused across every binding — provider cost shouldn't scale with
        // destination count.
        let ocr = OcrProviderFactory.make(
            provider: rule.ocrProviderOverride ?? self.settings.ocrProvider,
            model: self.settings.ocrModel
        )
        var transcripts: [(file: RmFile, result: OcrResult)] = []
        for file in files {
            transcripts.append((file, await transcribeFile(file, using: ocr)))
        }

        for binding in bindings {
            activeBindingId = binding.id
            await runBinding(rule: rule, folderName: folderName, binding: binding, transcripts: transcripts, ocrName: ocr.name)
        }
        activeBindingId = nil
    }

    /// Transcribes every page of one file and combines them into a single
    /// note-worth of text (and any Mermaid diagrams).
    private func transcribeFile(_ file: RmFile, using ocr: OcrProvider) async -> OcrResult {
        let pages = (try? await remarkable.listPages(notebookId: file.id)) ?? []
        var texts: [String] = []
        var mermaids: [String] = []
        for page in pages {
            guard let imageData = await imageData(for: page), !imageData.isEmpty else { continue }
            do {
                let result = try await ocr.transcribe(imageData: imageData)
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "[blank page]" { texts.append(trimmed) }
                if let mermaid = result.mermaidSource { mermaids.append(mermaid) }
            } catch {
                Log.ocr.error("OCR failed for file \(file.id, privacy: .public): \(Formatters.userMessage(for: error), privacy: .public)")
            }
        }
        return OcrResult(
            text: texts.isEmpty ? "[blank page]" : texts.joined(separator: "\n\n"),
            mermaidSource: mermaids.isEmpty ? nil : mermaids.joined(separator: "\n\n"),
            provider: ocr.name, model: nil, tokensIn: nil, tokensOut: nil
        )
    }

    private func runBinding(rule: SyncRule, folderName: String, binding: DestinationBinding,
                            transcripts: [(file: RmFile, result: OcrResult)], ocrName: String) async {
        let client = DestinationRouter.client(for: binding.kind)
        ledger.appendEvent(makeEvent(rule: rule, binding: binding, folderName: folderName, type: .ruleRunStarted))

        // Apply optional per-binding overrides on top of the rule defaults.
        var effectiveRule = rule
        if let titleOverride = binding.titleStrategyOverride { effectiveRule.titleStrategy = titleOverride }
        if let ocrModeOverride = binding.ocrModeOverride { effectiveRule.ocrMode = ocrModeOverride }

        var notesSynced = 0
        var firstError: String?
        let runStart = Date()

        for (file, ocrResult) in transcripts {
            let directive = engine.evaluate(
                rule: effectiveRule, file: file, folderName: folderName,
                ocrText: ocrResult.text,
                previouslySyncedHash: ledger.syncedHash(bindingId: binding.id, pageId: file.id)
            )
            guard case .create(let title) = directive else { continue }

            let payload = DestinationPayload(
                title: title,
                body: ocrResult.text,
                mermaidSource: ocrResult.mermaidSource,
                sourceDate: file.createdAt,
                pdfData: nil,
                ocrProvider: ocrName,
                ruleNotebookName: file.name,
                folderName: folderName,
                pageNumber: 1
            )
            do {
                let result = try await client.write(payload: payload, configuration: binding.configuration)
                notesSynced += 1
                ledger.recordSyncedPage(bindingId: binding.id, pageId: file.id, versionHash: file.versionHash)
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
            "status": status.rawValue,
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

    /// Page-image fetch is a placeholder until the real reMarkable client
    /// rasterises pages. Returning nil short-circuits the OCR call so we
    /// don't ship zero-byte uploads to the LLM providers.
    private func imageData(for page: RmPage) async -> Data? {
        // The real client downloads the page's .rm blob and rasterizes it; the
        // mock returns nil so a blank page is synthesized instead of uploading
        // empty bytes to an OCR provider.
        return try? await remarkable.pageImage(for: page)
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
