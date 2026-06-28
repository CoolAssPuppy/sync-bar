//
//  KeychainStore.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Security

/// Token storage. Prefers the **data-protection keychain** under a team-prefixed
/// access group: access is gated by the app's `keychain-access-groups`
/// entitlement, not a per-binary ACL, so reads never show the "allow keychain
/// access" prompt. Shipped (Developer ID) and Xcode builds carry that entitlement.
///
/// The command-line debug build signs ad-hoc (automatic signing can't apply the
/// managed profile without `-allowProvisioningUpdates`), so it lacks the
/// entitlement; there we transparently fall back to the legacy file-based
/// keychain. That keeps the dev loop working (with a dev-only prompt) while
/// shipped users get the prompt-free path.
///
/// `Sendable` because every method goes through the Security framework, which is
/// safe for concurrent use; the read cache is guarded by a lock.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()

    enum Key {
        case openaiApiKey
        case anthropicApiKey
        case remarkableDeviceToken
        case remarkableUserToken
        case notionWorkspaceToken(workspaceId: String)
        case linearAccessToken
        case googleAccessToken(email: String)
        case googleRefreshToken(email: String)
        case googleTokenExpiry(email: String)
        case xAccessToken(accountId: String)
        case xRefreshToken(accountId: String)
        case xTokenExpiry(accountId: String)

        fileprivate var account: String {
            switch self {
            case .openaiApiKey:                  return "ocr.openai.api_key"
            case .anthropicApiKey:               return "ocr.anthropic.api_key"
            case .remarkableDeviceToken:         return "remarkable.device_token"
            case .remarkableUserToken:           return "remarkable.user_token"
            case .notionWorkspaceToken(let id):  return "notion.workspace.\(id).access_token"
            case .linearAccessToken:             return "linear.access_token"
            case .googleAccessToken(let email):  return "google.\(email).access_token"
            case .googleRefreshToken(let email): return "google.\(email).refresh_token"
            case .googleTokenExpiry(let email):  return "google.\(email).token_expiry"
            case .xAccessToken(let id):          return "x.\(id).access_token"
            case .xRefreshToken(let id):         return "x.\(id).refresh_token"
            case .xTokenExpiry(let id):          return "x.\(id).token_expiry"
            }
        }
    }

    /// Must match the value the `keychain-access-groups` entitlement signs to
    /// (`$(AppIdentifierPrefix)com.strategicnerds.SyncBar`); the prefix is the
    /// team identifier.
    private static let service = "com.strategicnerds.SyncBar"
    private static let accessGroup = "955GSY56UT.com.strategicnerds.SyncBar"

    private let lock = NSLock()
    /// In-memory memo of reads so repeated lookups in a launch don't re-hit the
    /// keychain. Outer optional is "is it cached"; inner is the value (a cached
    /// `nil` means known-absent). Writes keep the cache in step.
    private var cache: [String: String?] = [:]

    private init() {}

    // MARK: Queries

    /// Entitlement-gated data-protection keychain (no prompt).
    private func protectedQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Legacy file-based keychain, used only when the entitlement is absent
    /// (ad-hoc dev builds).
    private func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: Public API

    func value(for key: Key) -> String? {
        let account = key.account
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var (value, status) = read(protectedQuery(account: account))
        if status == errSecMissingEntitlement {
            (value, status) = read(legacyQuery(account: account))
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.app.error("Keychain read failed for \(account, privacy: .public): \(status, privacy: .public)")
        }

        lock.lock()
        cache.updateValue(value, forKey: account)   // caches a nil result too
        lock.unlock()
        return value
    }

    func set(value: String, for key: Key) {
        if value.isEmpty {
            delete(key: key)
            return
        }
        let account = key.account
        let data = Data(value.utf8)

        var status = write(protectedQuery(account: account), data: data)
        if status == errSecMissingEntitlement {
            status = write(legacyQuery(account: account), data: data)
        }

        if status == errSecSuccess {
            lock.lock()
            cache.updateValue(value, forKey: account)
            lock.unlock()
        } else {
            Log.app.error("Keychain write failed for \(account, privacy: .public): \(status, privacy: .public)")
        }
    }

    func delete(key: Key) {
        var status = SecItemDelete(protectedQuery(account: key.account) as CFDictionary)
        if status == errSecMissingEntitlement {
            status = SecItemDelete(legacyQuery(account: key.account) as CFDictionary)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.app.error("Keychain delete failed for \(key.account, privacy: .public): \(status, privacy: .public)")
        }
        lock.lock()
        cache.updateValue(nil, forKey: key.account)   // cache as known-absent
        lock.unlock()
    }

    // MARK: SecItem helpers

    private func read(_ query: [String: Any]) -> (value: String?, status: OSStatus) {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = status == errSecSuccess
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        return (value, status)
    }

    /// Updates the item if it exists, otherwise adds it. Returns the final status.
    private func write(_ query: [String: Any], data: Data) -> OSStatus {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return update }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil)
    }
}
