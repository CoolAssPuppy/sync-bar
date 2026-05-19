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

    private func runRule(_ rule: SyncRule, restrictedToBindingId: String?) async {
        let runStart = Date()
        var pages: [RmPage] = []
        do {
            pages = try await remarkable.listPages(notebookId: rule.rmNotebookId)
        } catch {
            recordFailure(rule: rule, binding: nil, message: "\(error)")
            return
        }

        for binding in rule.destinations where binding.enabled
            && (restrictedToBindingId == nil || binding.id == restrictedToBindingId) {
            activeBindingId = binding.id
            await runBinding(rule: rule, binding: binding, pages: pages, cycleStartedAt: runStart)
        }
    }

    private func runBinding(rule: SyncRule, binding: DestinationBinding, pages: [RmPage], cycleStartedAt: Date) async {
        let client = DestinationRouter.client(for: binding.kind)
        let ocr = OcrProviderFactory.make(
            provider: rule.ocrProviderOverride ?? AppSettings.shared.ocrProvider,
            model: AppSettings.shared.ocrModel
        )

        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: rule.id, ruleName: ruleHeader(rule, binding: binding),
            eventType: .ruleRunStarted,
            rmNotebookName: rule.rmNotebookName, rmPageId: nil,
            notionPageUrl: nil, durationMs: nil, ocrProvider: ocr.name, errorMessage: nil
        ))

        var pagesSynced = 0
        var firstError: String?
        let runStart = Date()

        for page in pages {
            // OCR. In v0.1 we send Data() (no rasterized page) so Vision returns
            // [blank page] and the LLM providers return a polite placeholder.
            // When the real reMarkable PDF rasterizer lands, this loop unchanged.
            let ocrResult: OcrResult
            do {
                ocrResult = try await ocr.transcribe(imageData: Data())
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if firstError == nil { firstError = msg }
                Log.ocr.error("OCR failed for rule \(rule.id, privacy: .public): \(msg, privacy: .public)")
                continue
            }

            let directive = engine.evaluate(
                rule: rule, page: page,
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
                    pdfData: rule.savePdfAttachment ? nil : nil,
                    ocrProvider: ocr.name,
                    ruleNotebookName: rule.rmNotebookName,
                    pageNumber: page.positionInNotebook + 1
                )
                do {
                    let result = try await client.write(payload: payload, configuration: binding.configuration)
                    pagesSynced += 1
                    ledger.appendEvent(SyncEvent(
                        id: UUID().uuidString, occurredAt: Date(),
                        ruleId: rule.id, ruleName: ruleHeader(rule, binding: binding),
                        eventType: .pageSynced,
                        rmNotebookName: rule.rmNotebookName, rmPageId: page.pageId,
                        notionPageUrl: result.externalURL?.absoluteString,
                        durationMs: Int(Date().timeIntervalSince(runStart) * 1_000),
                        ocrProvider: ocr.name, errorMessage: nil
                    ))
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    if firstError == nil { firstError = msg }
                    ledger.appendEvent(SyncEvent(
                        id: UUID().uuidString, occurredAt: Date(),
                        ruleId: rule.id, ruleName: ruleHeader(rule, binding: binding),
                        eventType: .pageFailed,
                        rmNotebookName: rule.rmNotebookName, rmPageId: page.pageId,
                        notionPageUrl: nil, durationMs: nil,
                        ocrProvider: ocr.name, errorMessage: msg
                    ))
                }
            }
        }

        let status: RuleRunStatus = {
            if firstError != nil { return pagesSynced > 0 ? .partial : .error }
            return .success
        }()
        ledger.updateBindingRunResult(
            ruleId: rule.id, bindingId: binding.id,
            status: status, pagesSynced: pagesSynced, runAt: Date(),
            error: firstError
        )
        ledger.appendEvent(SyncEvent(
            id: UUID().uuidString, occurredAt: Date(),
            ruleId: rule.id, ruleName: ruleHeader(rule, binding: binding),
            eventType: .ruleRunCompleted,
            rmNotebookName: rule.rmNotebookName, rmPageId: nil,
            notionPageUrl: nil,
            durationMs: Int(Date().timeIntervalSince(runStart) * 1_000),
            ocrProvider: ocr.name, errorMessage: nil
        ))

        if firstError != nil, AppSettings.shared.notifyOnFailure {
            postNotification(title: "Sync failed",
                             body: "\(rule.rmNotebookName) → \(binding.configuration.summary)")
        } else if firstError == nil, AppSettings.shared.notifyOnSuccess {
            postNotification(title: "Sync complete",
                             body: "\(rule.rmNotebookName): \(Formatters.syncResultLabel(pageCount: pagesSynced))")
        }
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
