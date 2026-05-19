//
//  SyncCoordinator.swift
//  SyncNerds
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
         remarkable: RemarkableClient = MockRemarkableClient(),
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

    func start() { restartTimer() }
    func stop()  { timerTask?.cancel(); timerTask = nil }

    func syncNow(ruleId: String? = nil, bindingId: String? = nil) {
        guard !isSyncing else { return }
        Task { await runCycle(ruleId: ruleId, bindingId: bindingId) }
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
                await self.runCycle(ruleId: nil, bindingId: nil)
                self.nextTickAt = Date().addingTimeInterval(TimeInterval(seconds))
            }
        }
    }

    private func runCycle(ruleId: String?, bindingId: String?) async {
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

        for rule in rules {
            activeRuleId = rule.id
            await runRule(rule, restrictedToBindingId: bindingId)
        }

        activeRuleId = nil
        activeBindingId = nil
        lastTickAt = Date()
        isSyncing = false
        NotificationCenter.default.post(name: .syncFinished, object: nil)
    }

    /// Maximum number of destinations we sync in parallel within one rule.
    /// Apple Notes uses AppleScript and gets cranky under contention; three
    /// is a comfortable ceiling.
    private static let maxBindingConcurrency = 3

    private func runRule(_ rule: SyncRule, restrictedToBindingId: String?) async {
        var pages: [RmPage] = []
        do {
            pages = try await remarkable.listPages(notebookId: rule.rmNotebookId)
        } catch {
            recordFailure(rule: rule, binding: nil, message: Formatters.userMessage(for: error))
            return
        }

        // OCR once per page (one transcription, fanned out to every binding)
        // instead of once per (page × binding). Same image, same model, same
        // result, so destination-count multiplies cost without value.
        let ocr = OcrProviderFactory.make(
            provider: rule.ocrProviderOverride ?? self.settings.ocrProvider,
            model: self.settings.ocrModel
        )
        var ocrResults: [(page: RmPage, result: OcrResult)] = []
        for page in pages {
            // The real client (when paired) will return the rasterized PNG
            // for this page. Until that lands, skip the OCR call entirely
            // and synthesize a `[blank page]` result so the rules engine
            // can still drive create/skip decisions deterministically and
            // we don't upload empty bytes to OpenAI / Anthropic.
            guard let imageData = await imageData(for: page), !imageData.isEmpty else {
                ocrResults.append((page, OcrResult(
                    text: "[blank page]",
                    mermaidSource: nil,
                    provider: ocr.name,
                    model: nil,
                    tokensIn: nil,
                    tokensOut: nil
                )))
                continue
            }
            do {
                let result = try await ocr.transcribe(imageData: imageData)
                ocrResults.append((page, result))
            } catch {
                let message = Formatters.userMessage(for: error)
                Log.ocr.error("OCR failed for rule \(rule.id, privacy: .public): \(message, privacy: .public)")
                // Record the OCR failure on the rule (no binding yet —
                // OCR sits above the per-binding fan-out) so the sync log
                // explains why a page never reached its destination.
                ledger.appendEvent(SyncEvent(
                    id: UUID().uuidString, occurredAt: Date(),
                    ruleId: rule.id, ruleName: rule.rmNotebookName,
                    eventType: .pageFailed,
                    rmNotebookName: rule.rmNotebookName, rmPageId: page.pageId,
                    notionPageUrl: nil, durationMs: nil,
                    ocrProvider: ocr.name, errorMessage: "OCR: \(message)"
                ))
            }
        }

        let bindings = rule.destinations.filter { binding in
            binding.enabled && (restrictedToBindingId == nil || binding.id == restrictedToBindingId)
        }

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for binding in bindings {
                if inFlight >= Self.maxBindingConcurrency {
                    await group.next()
                    inFlight -= 1
                }
                let context = BindingRunContext(rule: rule, binding: binding, ocrResults: ocrResults, ocrName: ocr.name)
                group.addTask { [weak self] in
                    await self?.runBinding(context: context)
                }
                inFlight += 1
            }
        }
    }

    private struct BindingRunContext {
        let rule: SyncRule
        let binding: DestinationBinding
        let ocrResults: [(page: RmPage, result: OcrResult)]
        let ocrName: String
    }

    private func runBinding(context: BindingRunContext) async {
        let client = DestinationRouter.client(for: context.binding.kind)
        activeBindingId = context.binding.id
        ledger.appendEvent(makeEvent(context: context, type: .ruleRunStarted))

        var pagesSynced = 0
        var firstError: String?
        let runStart = Date()

        for (page, ocrResult) in context.ocrResults {
            let directive = engine.evaluate(
                rule: context.rule, page: page,
                ocrText: ocrResult.text, previouslySyncedHash: nil
            )
            switch directive {
            case .skip:
                continue
            case .create(let title):
                let payload = DestinationPayload(
                    title: title,
                    body: ocrResult.text,
                    mermaidSource: ocrResult.mermaidSource,
                    sourceDate: page.createdAt,
                    pdfData: nil,
                    ocrProvider: context.ocrName,
                    ruleNotebookName: context.rule.rmNotebookName,
                    pageNumber: page.positionInNotebook + 1
                )
                do {
                    let result = try await client.write(payload: payload, configuration: context.binding.configuration)
                    pagesSynced += 1
                    ledger.appendEvent(makeEvent(
                        context: context, type: .pageSynced,
                        pageId: page.pageId, url: result.externalURL?.absoluteString,
                        durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)
                    ))
                } catch {
                    let msg = Formatters.userMessage(for: error)
                    if firstError == nil { firstError = msg }
                    ledger.appendEvent(makeEvent(
                        context: context, type: .pageFailed,
                        pageId: page.pageId, errorMessage: msg
                    ))
                }
            }
        }

        let status: RuleRunStatus = {
            if firstError != nil { return pagesSynced > 0 ? .partial : .error }
            return .success
        }()
        ledger.updateBindingRunResult(
            ruleId: context.rule.id, bindingId: context.binding.id,
            status: status, pagesSynced: pagesSynced, runAt: Date(),
            error: firstError
        )
        ledger.appendEvent(makeEvent(
            context: context, type: .ruleRunCompleted,
            durationMs: Int(Date().timeIntervalSince(runStart) * 1_000)
        ))

        if firstError != nil, self.settings.notifyOnFailure {
            postNotification(title: "Sync failed",
                             body: "\(context.rule.rmNotebookName) → \(context.binding.configuration.summary)")
        } else if firstError == nil, pagesSynced > 0, self.settings.notifyOnSuccess {
            // Quiet cycles (all pages skipped because unchanged) don't earn
            // a notification; otherwise opting in to success notifications
            // means a banner every interval.
            postNotification(title: "Sync complete",
                             body: "\(context.rule.rmNotebookName): \(Formatters.syncResultLabel(pageCount: pagesSynced))")
        }
    }

    private func makeEvent(context: BindingRunContext,
                           type: SyncEventType,
                           pageId: String? = nil,
                           url: String? = nil,
                           durationMs: Int? = nil,
                           errorMessage: String? = nil) -> SyncEvent {
        SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: context.rule.id, ruleName: ruleHeader(context.rule, binding: context.binding),
            eventType: type,
            rmNotebookName: context.rule.rmNotebookName, rmPageId: pageId,
            notionPageUrl: url, durationMs: durationMs,
            ocrProvider: context.ocrName, errorMessage: errorMessage
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
        // TODO(remarkable-cloud): replace with the rasterized PNG once the
        // sync/v3 index walker lands.
        return nil
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
