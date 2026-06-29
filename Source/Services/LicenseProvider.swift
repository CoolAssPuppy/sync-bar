//
//  LicenseProvider.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The provider-neutral seam for the paid Sync class. The concrete subscription
//  provider (Polar today) hides behind `LicenseProvider`, so swapping it is one
//  new conformer rather than a sweep through the entitlement code. `LicenseStatus`
//  is the normalized snapshot every provider maps its response onto.
//

import Foundation

/// One device's license activation: the activation id to replay on validate and
/// deactivate, plus the status captured at activation time.
struct LicenseActivation: Equatable, Sendable {
    let activationId: String
    let status: LicenseStatus
}

/// A normalized, point-in-time license snapshot, provider-agnostic.
struct LicenseStatus: Equatable, Sendable {
    /// The provider's verdict. `granted` is the only entitled state; `revoked`
    /// and `disabled` are explicit lapses; `unknown` covers an unrecognized value.
    enum State: String, Sendable {
        case granted, revoked, disabled, unknown
    }

    let state: State
    /// Paid-through date when the provider supplies one. Used for grace: a
    /// transient network failure never locks out a payer before this passes.
    let expiresAt: Date?
    /// The provider's customer id, used to attribute metered usage. nil if absent.
    let customerId: String?

    var isGranted: Bool { state == .granted }
}

/// Provider-neutral license operations. Network failures surface as the
/// underlying `URLError` (the caller treats those as "couldn't reach the server"
/// and applies grace); semantic failures (bad key, activation limit) surface as
/// `LicenseError`.
protocol LicenseProvider: Sendable {
    /// Activates the key on this device, returning the activation to persist.
    func activate(key: String, deviceLabel: String) async throws -> LicenseActivation
    /// Re-checks the key (optionally pinned to an activation), returning fresh status.
    func validate(key: String, activationId: String?) async throws -> LicenseStatus
    /// Releases this device's activation (when removing the license locally).
    func deactivate(key: String, activationId: String) async throws
}

/// Semantic (non-network) failures from a license operation.
enum LicenseError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidKey
    case activationLimitReached
    case requestFailed(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Subscriptions aren't available in this build yet."
        case .invalidKey:
            return "That license key wasn't recognized. Check it and try again."
        case .activationLimitReached:
            return "This license is already active on the maximum number of devices. Remove it from one first."
        case .requestFailed(let status, let message):
            return "Couldn't reach the subscription service (HTTP \(status)): \(message)"
        case .invalidResponse(let message):
            return message
        }
    }
}
