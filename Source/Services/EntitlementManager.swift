//
//  EntitlementManager.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Owns entitlement for the paid Sync classes: the license key + activation id
//  (Keychain), the cached status/expiry per `PaidFeature` (UserDefaults), the
//  daily 00:00 Pacific re-check plus a launch check, and the derived gate the
//  add/run/row checks consult. The subscription provider hides behind
//  `LicenseProvider`, so it stays swappable.
//
//  Grace: a successful validate refreshes the record. A network or transient
//  server failure keeps the prior record untouched — `expiresAt` is the
//  authoritative paid-through date, so a payer is never locked out by a blip; the
//  gate only fails closed once `expiresAt` passes with no fresh grant. An explicit
//  bad key lapses immediately.
//

import Foundation
import Combine

/// The cached, persisted entitlement snapshot for one paid feature.
struct EntitlementRecord: Codable, Equatable, Sendable {
    var statusRaw: String
    var expiresAt: Date?
    var customerId: String?
    var lastValidatedAt: Date?

    var state: LicenseStatus.State { LicenseStatus.State(rawValue: statusRaw) ?? .unknown }

    init(statusRaw: String, expiresAt: Date?, customerId: String?, lastValidatedAt: Date?) {
        self.statusRaw = statusRaw
        self.expiresAt = expiresAt
        self.customerId = customerId
        self.lastValidatedAt = lastValidatedAt
    }

    init(from status: LicenseStatus, validatedAt: Date) {
        self.statusRaw = status.state.rawValue
        self.expiresAt = status.expiresAt
        self.customerId = status.customerId
        self.lastValidatedAt = validatedAt
    }
}

/// The user-facing state of a paid feature.
enum EntitlementState: Equatable, Sendable {
    case active        // paid up, the source runs
    case lapsed        // subscribed before, now expired/revoked — syncs go inactive
    case none          // never subscribed
}

@MainActor
final class EntitlementManager: ObservableObject {
    static let shared = EntitlementManager()

    /// Cached entitlement per feature, the source of truth for every gate.
    @Published private(set) var records: [PaidFeature: EntitlementRecord]

    private let provider: LicenseProvider
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private var dailyTask: Task<Void, Never>?

    private static let storageKey = "entitlement.records.v1"

    init(provider: LicenseProvider = PolarLicenseClient(),
         keychain: KeychainStore = .shared,
         defaults: UserDefaults = AppSettings.defaults,
         clock: @escaping @Sendable () -> Date = { Date() },
         timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current) {
        self.provider = provider
        self.keychain = keychain
        self.defaults = defaults
        self.clock = clock
        self.timeZone = timeZone
        self.records = Self.loadRecords(from: defaults)
    }

    // MARK: Lifecycle

    /// Validates on launch and schedules the daily 00:00 Pacific re-check.
    func start() {
        Task { await validateAll() }
        scheduleDailyCheck()
    }

    /// Re-validates every paid feature. NOTE: license storage is currently a
    /// single keychain key shared across features, so this is correct only while
    /// there is one paid feature. A second `PaidFeature` needs per-feature key
    /// storage (and a product -> feature mapping) before this loop is meaningful.
    private func validateAll() async {
        for feature in PaidFeature.allCases { await validateNow(for: feature) }
    }

    func stop() {
        dailyTask?.cancel()
        dailyTask = nil
    }

    // MARK: Derived gate

    /// Whether a paid feature is currently entitled (granted and not past expiry).
    func isEntitled(to feature: PaidFeature) -> Bool {
        Self.isEntitled(record: records[feature], now: clock())
    }

    /// The gate the run/add/row checks use: free sources are always allowed; a
    /// paid source is allowed only when its class is entitled.
    func isEntitled(forSource kind: SourceKind) -> Bool {
        guard let feature = kind.paidFeature else { return true }
        return isEntitled(to: feature)
    }

    /// The user-facing state for a feature, distinguishing "never subscribed"
    /// from "subscribed and lapsed".
    func state(for feature: PaidFeature) -> EntitlementState {
        guard let record = records[feature] else { return .none }
        return Self.isEntitled(record: record, now: clock()) ? .active : .lapsed
    }

    /// The provider customer id for a feature, used to attribute metered usage.
    func customerId(for feature: PaidFeature) -> String? { records[feature]?.customerId }

    // MARK: Operations

    /// Activates a pasted key for a feature, persisting the key + activation id.
    func activate(key: String, for feature: PaidFeature = .twitter) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LicenseError.invalidKey }
        let activation = try await provider.activate(key: trimmed, deviceLabel: Self.deviceLabel())
        keychain.set(value: trimmed, for: .licenseKey)
        keychain.set(value: activation.activationId, for: .licenseActivationId)
        apply(EntitlementRecord(from: activation.status, validatedAt: clock()), for: feature)
    }

    /// Re-validates the stored key and folds the outcome in (with grace).
    func validateNow(for feature: PaidFeature = .twitter) async {
        guard let key = keychain.value(for: .licenseKey), !key.isEmpty else { return }
        let activationId = keychain.value(for: .licenseActivationId)
        let result: Result<LicenseStatus, Error>
        do {
            result = .success(try await provider.validate(key: key, activationId: activationId))
        } catch {
            result = .failure(error)
        }
        let updated = Self.reduce(current: records[feature], result: result, now: clock())
        if let updated {
            apply(updated, for: feature)
        }
    }

    /// Removes the license from this device (deactivates the instance remotely,
    /// best-effort) and clears the cached entitlement.
    func removeLicense(for feature: PaidFeature = .twitter) async {
        if let key = keychain.value(for: .licenseKey), !key.isEmpty,
           let activationId = keychain.value(for: .licenseActivationId), !activationId.isEmpty {
            try? await provider.deactivate(key: key, activationId: activationId)
        }
        keychain.delete(key: .licenseKey)
        keychain.delete(key: .licenseActivationId)
        records[feature] = nil
        persist()
    }

    // MARK: Pure logic (unit-tested)

    /// The gate: entitled iff the record is `granted` and not past its expiry.
    /// A nil/expired/revoked/disabled/unknown record is not entitled.
    nonisolated static func isEntitled(record: EntitlementRecord?, now: Date) -> Bool {
        guard let record, record.state == .granted else { return false }
        if let expiresAt = record.expiresAt { return now < expiresAt }
        return true
    }

    /// Folds a validate outcome into the cached record, encoding the grace rule.
    /// Success replaces the record; an explicit bad key lapses; any other failure
    /// (network, transient server error) keeps the prior record so a blip never
    /// locks out a payer before `expiresAt`.
    nonisolated static func reduce(current: EntitlementRecord?, result: Result<LicenseStatus, Error>, now: Date) -> EntitlementRecord? {
        switch result {
        case .success(let status):
            return EntitlementRecord(from: status, validatedAt: now)
        case .failure(let error as LicenseError) where error == .invalidKey:
            return EntitlementRecord(statusRaw: LicenseStatus.State.revoked.rawValue,
                                     expiresAt: current?.expiresAt,
                                     customerId: current?.customerId,
                                     lastValidatedAt: current?.lastValidatedAt)
        case .failure:
            return current
        }
    }

    /// Seconds until the next 00:00 in the given time zone, for the daily check.
    nonisolated static func secondsUntilNextMidnight(after now: Date, in timeZone: TimeZone) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime) else {
            return 24 * 60 * 60
        }
        return max(1, nextMidnight.timeIntervalSince(now))
    }

    // MARK: Internals

    private func apply(_ record: EntitlementRecord, for feature: PaidFeature) {
        records[feature] = record
        persist()
    }

    private func scheduleDailyCheck() {
        dailyTask?.cancel()
        dailyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = Self.secondsUntilNextMidnight(after: self.clock(), in: self.timeZone)
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self.validateAll()
            }
        }
    }

    private func persist() {
        let blob = records.reduce(into: [String: EntitlementRecord]()) { $0[$1.key.rawValue] = $1.value }
        if let data = try? JSONEncoder().encode(blob) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func loadRecords(from defaults: UserDefaults) -> [PaidFeature: EntitlementRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let blob = try? JSONDecoder().decode([String: EntitlementRecord].self, from: data) else {
            return [:]
        }
        return blob.reduce(into: [PaidFeature: EntitlementRecord]()) { acc, pair in
            if let feature = PaidFeature(rawValue: pair.key) { acc[feature] = pair.value }
        }
    }

    /// A friendly per-device label sent to the provider on activation, so the
    /// user can recognize each device in the customer portal.
    private static func deviceLabel() -> String {
        Host.current().localizedName ?? "Mac"
    }
}
