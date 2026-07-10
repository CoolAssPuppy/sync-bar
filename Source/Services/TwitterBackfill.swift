//
//  TwitterBackfill.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  One-shot maker tool, hidden behind right-clicking "Twitter" in Settings.
//  Rows synced before thread expansion existed hold only the tweet's first
//  line; this refills them in place. It adopts every existing row in the
//  Twitter rule's Notion database by its tweet URL (external id recorded, no
//  hash — so the next cycle re-renders into the SAME page instead of creating
//  a duplicate), forgets the bookmarks cursor so the whole history re-lists,
//  clears the month's read meter (the cap protects the maker's own API bill,
//  and this spend is deliberate), and kicks off a sync. Runs once per install.
//

import Foundation

@MainActor
enum TwitterBackfill {
    static let didRunDefaultsKey = "settings.twitterBackfill.didRun.v1"

    static var hasRun: Bool { AppSettings.defaults.bool(forKey: didRunDefaultsKey) }

    enum BackfillError: LocalizedError {
        case noTwitterRule
        case noNotionToken

        var errorDescription: String? {
            switch self {
            case .noTwitterRule: return "No Twitter rule with a Notion database destination was found."
            case .noNotionToken: return "Reconnect the Notion workspace first."
            }
        }
    }

    /// Runs the whole backfill. Returns how many existing rows were adopted.
    /// `ruleId` targets one rule; nil takes the first Twitter rule that writes
    /// into a Notion database.
    @discardableResult
    static func run(ruleId: String? = nil,
                    ledger: Ledger = .shared,
                    keychain: KeychainStore = .shared,
                    stateStore: XSyncStateStore = .shared,
                    readBudget: ReadBudget = ReadBudget(),
                    session: URLSession = .shared,
                    coordinator: SyncCoordinator?) async throws -> Int {
        let match = ledger.rules
            .filter { $0.sourceKind == .x && (ruleId == nil || $0.id == ruleId) }
            .compactMap { rule -> (rule: SyncRule, binding: DestinationBinding, config: NotionDestinationConfig)? in
                for binding in rule.destinations {
                    if case .notion(let cfg) = binding.configuration, cfg.destinationType == .database {
                        return (rule, binding, cfg)
                    }
                }
                return nil
            }
            .first
        guard let (rule, binding, notionConfig) = match,
              case .x(let sourceConfig) = rule.source else {
            throw BackfillError.noTwitterRule
        }
        guard let token = keychain.value(for: .notionWorkspaceToken(workspaceId: notionConfig.workspaceId)),
              !token.isEmpty else {
            throw BackfillError.noNotionToken
        }

        // Adopt every row whose URL column is a tweet permalink: the tweet id
        // becomes the page id the ledger already keys on, so the resync updates
        // that exact Notion page in place.
        var adopted = 0
        var cursor: String?
        repeat {
            let page = try await queryPage(databaseId: notionConfig.destinationId,
                                           startCursor: cursor, token: token, session: session)
            for row in page.rows {
                guard let tweetId = tweetId(fromStatusURL: row.url) else { continue }
                ledger.adoptExternalId(bindingId: binding.id, pageId: tweetId, externalId: row.pageId)
                adopted += 1
            }
            cursor = page.nextCursor
        } while cursor != nil

        stateStore.reset(accountId: sourceConfig.accountId, stream: sourceConfig.stream)
        readBudget.resetMonth(now: Date())
        AppSettings.defaults.set(true, forKey: didRunDefaultsKey)
        Log.sync.info("Twitter backfill: adopted \(adopted, privacy: .public) rows; cursor + read meter reset")

        coordinator?.syncNow(ruleId: rule.id)
        return adopted
    }

    // MARK: Pure helpers (unit-tested)

    struct AdoptableRow: Equatable {
        let pageId: String
        let url: String
    }

    /// The numeric status id from a tweet permalink; nil for anything that
    /// isn't an x.com / twitter.com status URL.
    static func tweetId(fromStatusURL raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        let isTwitterHost = ["x.com", "twitter.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
        guard isTwitterHost else { return nil }
        let parts = url.pathComponents
        guard let statusIndex = parts.lastIndex(of: "status"), parts.indices.contains(statusIndex + 1) else {
            return nil
        }
        let id = parts[statusIndex + 1]
        return (!id.isEmpty && id.allSatisfy(\.isNumber)) ? id : nil
    }

    /// Parses one `/v1/databases/{id}/query` response into rows carrying each
    /// page's first url-typed property, plus the cursor for the next page.
    static func parseQueryPage(_ data: Data) throws -> (rows: [AdoptableRow], nextCursor: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw BackfillError.noTwitterRule
        }
        let rows: [AdoptableRow] = results.compactMap { result in
            guard let pageId = result["id"] as? String,
                  let properties = result["properties"] as? [String: Any] else { return nil }
            let url = properties.values
                .compactMap { $0 as? [String: Any] }
                .first { ($0["type"] as? String) == "url" && $0["url"] is String }
                .flatMap { $0["url"] as? String }
            guard let url else { return nil }
            return AdoptableRow(pageId: pageId, url: url)
        }
        let hasMore = (root["has_more"] as? Bool) ?? false
        let nextCursor = hasMore ? root["next_cursor"] as? String : nil
        return (rows, nextCursor)
    }

    // MARK: Networking

    private static func queryPage(databaseId: String, startCursor: String?,
                                  token: String, session: URLSession) async throws
        -> (rows: [AdoptableRow], nextCursor: String?) {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(databaseId)/query") else {
            throw BackfillError.noTwitterRule
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["page_size": 100]
        if let startCursor { body["start_cursor"] = startCursor }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "TwitterBackfill", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Notion query failed (HTTP \(http.statusCode)): \(snippet)"])
        }
        return try parseQueryPage(data)
    }
}

extension Notification.Name {
    /// Posted by the hidden Settings switch; AppDelegate owns the coordinator
    /// and runs the backfill.
    static let twitterBackfillRequested = Notification.Name("twitterBackfillRequested")
}
