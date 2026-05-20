//
//  RemarkableClient.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

enum RemarkableError: LocalizedError, Sendable {
    case invalidOneTimeCode
    case deviceNotPaired
    case rateLimited
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidOneTimeCode: return "That one-time code wasn't valid."
        case .deviceNotPaired:    return "Connect a reMarkable first."
        case .rateLimited:        return "The reMarkable cloud is throttling us. Try again in a minute."
        case .network(let msg):   return msg
        }
    }
}

protocol RemarkableClient: Sendable {
    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount
    func listNotebooks() async throws -> [RmNotebook]
    func listPages(notebookId: String) async throws -> [RmPage]
    /// A rasterized PNG of the page, used as the OCR input. Returns nil when no
    /// rendering is available (e.g. the mock client), in which case the sync
    /// engine treats the page as blank rather than uploading empty bytes.
    func pageImage(for page: RmPage) async throws -> Data?
}

/// Returns the live reMarkable client once a device is paired (a device token
/// is in the keychain), otherwise the mock so the UI stays explorable.
enum RemarkableClientFactory {
    static func make(keychain: KeychainStore = .shared) -> RemarkableClient {
        if let token = keychain.value(for: .remarkableDeviceToken), !token.isEmpty {
            return RealRemarkableClient(keychain: keychain)
        }
        return MockRemarkableClient()
    }
}

/// Deterministic mock client. Returns sample notebooks and pages drawn from
/// a fixed list so the UI looks lived-in before the real device is paired.
struct MockRemarkableClient: RemarkableClient {
    private static let sampleNotebooks: [RmNotebook] = [
        RmNotebook(id: "nb-journal",   name: "Daily journal", parentFolder: "Personal", lastModified: Date().addingTimeInterval(-3_600 * 5), pageCount: 52),
        RmNotebook(id: "nb-meetings",  name: "Weekly 1:1s", parentFolder: "Work", lastModified: Date().addingTimeInterval(-3_600 * 9), pageCount: 14),
        RmNotebook(id: "nb-standup",   name: "Standup notes", parentFolder: "Work", lastModified: Date().addingTimeInterval(-3_600 * 26), pageCount: 31),
        RmNotebook(id: "nb-quarterly", name: "Q3 planning", parentFolder: "Work", lastModified: Date().addingTimeInterval(-3_600 * 48), pageCount: 8),
        RmNotebook(id: "nb-research",  name: "Customer interviews", parentFolder: "Work", lastModified: Date().addingTimeInterval(-3_600 * 72), pageCount: 17),
        RmNotebook(id: "nb-book",      name: "Architecture sketches", parentFolder: "Projects", lastModified: Date().addingTimeInterval(-3_600 * 96), pageCount: 13),
        RmNotebook(id: "nb-onboard",   name: "Reading notes", parentFolder: "Personal", lastModified: Date().addingTimeInterval(-3_600 * 120), pageCount: 26),
        RmNotebook(id: "nb-travel",    name: "Japan trip planning", parentFolder: "Personal", lastModified: Date().addingTimeInterval(-3_600 * 168), pageCount: 9)
    ]

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        // Simulate latency.
        try await Task.sleep(nanoseconds: 600_000_000)
        let trimmed = oneTimeCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 8 else { throw RemarkableError.invalidOneTimeCode }
        return RemarkableAccount(
            pairedAt: Date(),
            userIdentifier: "rm-\(trimmed.prefix(6))",
            lastSyncedAt: nil
        )
    }

    func listNotebooks() async throws -> [RmNotebook] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return Self.sampleNotebooks
    }

    func listPages(notebookId: String) async throws -> [RmPage] {
        try await Task.sleep(nanoseconds: 150_000_000)
        guard let notebook = Self.sampleNotebooks.first(where: { $0.id == notebookId }) else {
            return []
        }
        return (0..<notebook.pageCount).map { index in
            RmPage(
                notebookId: notebookId,
                pageId: "page-\(index)",
                positionInNotebook: index,
                createdAt: notebook.lastModified.addingTimeInterval(TimeInterval(-3_600 * index)),
                modifiedAt: notebook.lastModified.addingTimeInterval(TimeInterval(-1_800 * index)),
                hasTypedText: index % 4 != 0,
                versionHash: "hash-\(notebookId)-\(index)"
            )
        }
    }

    func pageImage(for page: RmPage) async throws -> Data? { nil }
}
