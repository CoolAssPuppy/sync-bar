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
    func downloadNotebookPdf(notebookId: String) async throws -> Data
}

/// Deterministic mock client. Returns sample notebooks and pages drawn from
/// a fixed list so the UI looks lived-in before the real device is paired.
struct MockRemarkableClient: RemarkableClient {
    private static let sampleNotebooks: [RmNotebook] = [
        RmNotebook(id: "nb-quarterly", name: "Q2 planning", parentFolder: "Strategy", lastModified: Date().addingTimeInterval(-3_600 * 6), pageCount: 7),
        RmNotebook(id: "nb-meetings",  name: "Meeting notes", parentFolder: nil, lastModified: Date().addingTimeInterval(-3_600 * 18), pageCount: 24),
        RmNotebook(id: "nb-journal",   name: "Daily journal", parentFolder: "Personal", lastModified: Date().addingTimeInterval(-3_600 * 30), pageCount: 41),
        RmNotebook(id: "nb-book",      name: "Book sketches", parentFolder: "Personal", lastModified: Date().addingTimeInterval(-3_600 * 48), pageCount: 12),
        RmNotebook(id: "nb-research",  name: "Customer research", parentFolder: "Strategy", lastModified: Date().addingTimeInterval(-3_600 * 96), pageCount: 18),
        RmNotebook(id: "nb-onboard",   name: "Onboarding ideas", parentFolder: "Strategy", lastModified: Date().addingTimeInterval(-3_600 * 120), pageCount: 9)
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

    func downloadNotebookPdf(notebookId: String) async throws -> Data {
        // Not used in the overnight build; returns an empty Data for now.
        try await Task.sleep(nanoseconds: 200_000_000)
        return Data()
    }
}
