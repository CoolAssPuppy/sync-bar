//
//  CloudKitLedger.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Mirrors a subset of the `Ledger` API onto CloudKit private database
//  records. This file is the scaffolding for the v0.3 migration off
//  UserDefaults; on first launch with an iCloud account available, the
//  app starts mirroring writes here in the background.
//
//  Schema (private database, default zone):
//    SyncRule
//      recordName    String       (UUID, matches in-memory SyncRule.id)
//      blob          Data         (JSONEncoded SyncRule including destinations)
//      updatedAt     Date
//    NotionWorkspace, LinearAccount, GoogleAccount, AppleNotesTarget,
//    MarkdownTarget, RemarkableAccount, AppSettings each follow the same
//    pattern (one record type, JSON blob, updatedAt for last-writer-wins).
//
//  Rationale for the JSON-blob approach: schema migrations are painful in
//  CloudKit. Storing the full struct as a Codable blob lets us evolve the
//  in-Swift model without redeploying the CloudKit schema each time. The
//  cost is no server-side filtering, but our records-per-user counts are
//  tiny (rules, events, etc. are at most a few hundred per user).
//

import Foundation
import CloudKit
import Combine

@MainActor
final class CloudKitLedger: ObservableObject {
    nonisolated static let containerIdentifier = "iCloud.com.strategicnerds.syncnerds"

    enum RecordType: String {
        case syncRule          = "SyncRule"
        case syncEvent         = "SyncEvent"
        case remarkableAccount = "RemarkableAccount"
        case notionWorkspace   = "NotionWorkspace"
        case linearAccount     = "LinearAccount"
        case googleAccount     = "GoogleAccount"
        case markdownTarget    = "MarkdownTarget"
        case appleNotesTarget  = "AppleNotesTarget"
        case appSettings       = "AppSettings"
    }

    private let container: CKContainer
    private let database: CKDatabase

    @Published private(set) var lastSyncError: String?
    @Published private(set) var isAvailable: Bool = false

    init(containerIdentifier: String = CloudKitLedger.containerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        Task { await checkAvailability() }
    }

    // MARK: - Availability

    func checkAvailability() async {
        do {
            let status = try await container.accountStatus()
            isAvailable = (status == .available)
        } catch {
            isAvailable = false
            lastSyncError = error.localizedDescription
        }
    }

    // MARK: - Upsert / fetch as JSON blobs

    func upsert<T: Codable>(_ value: T, recordName: String, type: RecordType) async throws {
        guard isAvailable else { return }
        let recordID = CKRecord.ID(recordName: recordName)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            record = CKRecord(recordType: type.rawValue, recordID: recordID)
        }
        let data = try JSONEncoder().encode(value)
        record["blob"] = data as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func fetchAll<T: Codable>(_ type: RecordType, as: T.Type) async throws -> [T] {
        guard isAvailable else { return [] }
        let query = CKQuery(recordType: type.rawValue, predicate: NSPredicate(value: true))
        let (results, _) = try await database.records(matching: query)
        var output: [T] = []
        for (_, result) in results {
            if case .success(let record) = result,
               let data = record["blob"] as? Data {
                if let value = try? JSONDecoder().decode(T.self, from: data) {
                    output.append(value)
                }
            }
        }
        return output
    }

    func delete(recordName: String) async throws {
        guard isAvailable else { return }
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
    }

    // MARK: - Convenience wrappers

    func push(rule: SyncRule) async throws {
        try await upsert(rule, recordName: rule.id, type: .syncRule)
    }
    func push(event: SyncEvent) async throws {
        try await upsert(event, recordName: event.id, type: .syncEvent)
    }
    func push(remarkable: RemarkableAccount?) async throws {
        if let remarkable {
            try await upsert(remarkable, recordName: "singleton", type: .remarkableAccount)
        }
    }
    func push(workspace: NotionWorkspace) async throws {
        try await upsert(workspace, recordName: workspace.id, type: .notionWorkspace)
    }
    func push(account: LinearAccount) async throws {
        try await upsert(account, recordName: account.id, type: .linearAccount)
    }
    func push(account: GoogleAccount) async throws {
        try await upsert(account, recordName: account.id, type: .googleAccount)
    }
    func push(target: MarkdownTarget) async throws {
        try await upsert(target, recordName: target.id, type: .markdownTarget)
    }
    func push(target: AppleNotesTarget) async throws {
        try await upsert(target, recordName: target.id, type: .appleNotesTarget)
    }
}
