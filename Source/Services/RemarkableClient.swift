//
//  RemarkableClient.swift
//  SyncBar
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
    /// Top-level folders (the rule targets). A synthetic "Unfiled" folder is
    /// included only when files exist at the cloud root.
    func listNotebooks() async throws -> [RmNotebook]
    /// The files (notes) inside a folder. Each becomes one destination note.
    /// Each file carries its document-level reMarkable tags.
    func listFiles(inFolderId folderId: String) async throws -> [RmFile]
    /// The unique set of document tags configured across the whole account,
    /// sorted for display. Used to populate per-destination tag filters.
    func listTags() async throws -> [String]
    /// Pages of a single file (`notebookId` is a file id). Their transcriptions
    /// are combined into one note.
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
            Log.remarkable.info("client: REAL (device token present, \(token.count, privacy: .public) chars)")
            return RealRemarkableClient(keychain: keychain)
        }
        Log.remarkable.info("client: MOCK (no device token in keychain — returning sample folders)")
        return MockRemarkableClient()
    }
}

/// Deterministic mock client. Returns sample folders and files so the UI looks
/// lived-in before the real device is paired.
struct MockRemarkableClient: RemarkableClient {
    private static func ago(_ hours: Double) -> Date { Date().addingTimeInterval(-3_600 * hours) }

    private static let folders: [RmNotebook] = [
        RmNotebook(id: "f-work",     name: "Work",     parentFolder: nil, lastModified: ago(5),  pageCount: 3),
        RmNotebook(id: "f-personal", name: "Personal", parentFolder: nil, lastModified: ago(9),  pageCount: 2),
        RmNotebook(id: "f-projects", name: "Projects", parentFolder: nil, lastModified: ago(96), pageCount: 2)
    ]

    // Column-aligned sample fixtures read better on one line each.
    // swiftlint:disable line_length
    private static let files: [RmFile] = [
        RmFile(id: "file-standup",   name: "Standup notes",        folderId: "f-work",     createdAt: ago(26),  lastModified: ago(5),   pageCount: 3, versionHash: "h-standup",   tags: ["Action", "Work"]),
        RmFile(id: "file-1on1",      name: "Weekly 1:1s",          folderId: "f-work",     createdAt: ago(9),   lastModified: ago(9),   pageCount: 2, versionHash: "h-1on1",      tags: ["Work"]),
        RmFile(id: "file-quarterly", name: "Q3 planning",          folderId: "f-work",     createdAt: ago(48),  lastModified: ago(48),  pageCount: 1, versionHash: "h-quarterly",  tags: ["Action", "Planning"]),
        RmFile(id: "file-journal",   name: "Daily journal",        folderId: "f-personal", createdAt: ago(5),   lastModified: ago(5),   pageCount: 2, versionHash: "h-journal"),
        RmFile(id: "file-travel",    name: "Japan trip planning",  folderId: "f-personal", createdAt: ago(168), lastModified: ago(168), pageCount: 2, versionHash: "h-travel",     tags: ["Planning"]),
        RmFile(id: "file-arch",      name: "Architecture sketches",folderId: "f-projects", createdAt: ago(96),  lastModified: ago(96),  pageCount: 2, versionHash: "h-arch",       tags: ["Idea"]),
        RmFile(id: "file-book",      name: "Book outline",         folderId: "f-projects", createdAt: ago(120), lastModified: ago(120), pageCount: 1, versionHash: "h-book",       tags: ["Idea"])
    ]
    // swiftlint:enable line_length

    func pairDevice(oneTimeCode: String) async throws -> RemarkableAccount {
        try await Task.sleep(nanoseconds: 600_000_000)
        let trimmed = oneTimeCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 8 else { throw RemarkableError.invalidOneTimeCode }
        return RemarkableAccount(pairedAt: Date(), userIdentifier: "rm-\(trimmed.prefix(6))", lastSyncedAt: nil)
    }

    func listNotebooks() async throws -> [RmNotebook] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return Self.folders
    }

    func listFiles(inFolderId folderId: String) async throws -> [RmFile] {
        try await Task.sleep(nanoseconds: 100_000_000)
        return Self.files.filter { $0.folderId == folderId }
    }

    func listTags() async throws -> [String] {
        Array(Set(Self.files.flatMap(\.tags))).sorted()
    }

    func listPages(notebookId: String) async throws -> [RmPage] {
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let file = Self.files.first(where: { $0.id == notebookId }) else { return [] }
        return (0..<file.pageCount).map { index in
            RmPage(
                notebookId: notebookId,
                pageId: "page-\(index)",
                positionInNotebook: index,
                createdAt: file.createdAt,
                modifiedAt: file.lastModified,
                hasTypedText: true,
                versionHash: "\(file.versionHash)-\(index)"
            )
        }
    }

    func pageImage(for page: RmPage) async throws -> Data? { nil }
}
