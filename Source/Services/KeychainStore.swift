//
//  KeychainStore.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import KeychainAccess

/// Thin wrapper around KeychainAccess so callers never deal with raw service
/// and account strings. Synchronizable items live in iCloud Keychain.
/// `Sendable` because KeychainAccess.Keychain is itself thread-safe — every
/// method calls into the underlying Security framework which is safe for
/// concurrent reads and writes.
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
            }
        }
    }

    private let keychain: Keychain

    private init() {
        keychain = Keychain(service: "com.strategicnerds.SyncNerdsApp")
            .synchronizable(true)
            .accessibility(.afterFirstUnlock)
    }

    func value(for key: Key) -> String? {
        try? keychain.get(key.account)
    }

    func set(value: String, for key: Key) {
        if value.isEmpty {
            delete(key: key)
            return
        }
        do {
            try keychain.set(value, key: key.account)
        } catch {
            Log.app.error("Failed to write Keychain key \(key.account, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func delete(key: Key) {
        try? keychain.remove(key.account)
    }
}
