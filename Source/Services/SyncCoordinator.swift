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
    private let remarkable: RemarkableClient
    private let engine: RulesEngine
    private var timerTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(ledger: Ledger? = nil,
         remarkable: RemarkableClient = MockRemarkableClient(),
         engine: RulesEngine = RulesEngine()) {
        self.ledger = ledger ?? Ledger.shared
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
        let interval = AppSettings.shared.syncIntervalSeconds
        guard interval > 0, !AppSettings.shared.pauseSyncing else {
            nextTickAt = nil
            return
        }
        nextTickAt = Date().addingTimeInterval(TimeInterval(interval))
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.runCycle(ruleId: nil, bindingId: nil)
                await MainActor.run { [weak self] in
                    self?.nextTickAt = Date().addingTimeInterval(TimeInterval(interval))
                }
            }
        }
    }

    private func runCycle(ruleId: String?, bindingId: String?) async {
        guard ledger.remarkableAccount != nil else {
            Log.sync.info("Skipping cycle: no reMarkable account paired.")
            return
        }
        guard !AppSettings.shared.pauseSyncing else { return }

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
            provider: rule.ocrProviderOverride ?? AppSettings.shared.ocrProvider,
            model: AppSettings.shared.ocrModel
        )
        var ocrResults: [(page: RmPage, result: OcrResult)] = []
        for page in pages {
            do {
                let result = try await ocr.transcribe(imageData: Data())
                ocrResults.append((page, result))
            } catch {
                Log.ocr.error("OCR failed for rule \(rule.id, privacy: .public): \(String(describing: error), privacy: .public)")
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

        if firstError != nil, AppSettings.shared.notifyOnFailure {
            postNotification(title: "Sync failed",
                             body: "\(context.rule.rmNotebookName) → \(context.binding.configuration.summary)")
        } else if firstError == nil, AppSettings.shared.notifyOnSuccess {
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

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
