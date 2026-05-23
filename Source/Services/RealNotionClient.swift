//
//  RealNotionClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Notion API v2022-06-28 client used for catalog operations:
//    • Search for pages and databases the integration can see.
//    • Retrieve database schema.
//
//  Writing into Notion is handled by NotionDestinationClient. This file
//  exists so that the rules sheet can refresh its dropdowns against a
//  real Notion workspace once an OAuth token is stored in Keychain.
//

import Foundation

/// Returns the real Notion client when a workspace token is in Keychain,
/// the mock otherwise. Lets the binding editor and the sync coordinator
/// stay client-agnostic.
enum NotionClientFactory {
    static func make(workspaceId: String?, keychain: KeychainStore = .shared) -> NotionClient {
        if let workspaceId,
           let token = keychain.value(for: .notionWorkspaceToken(workspaceId: workspaceId)),
           !token.isEmpty {
            return RealNotionClient(token: token)
        }
        return MockNotionClient()
    }
}

struct RealNotionClient: NotionClient {
    let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func listDestinations(workspaceId: String) async throws -> [NotionDestination] {
        var request = URLRequest(url: URL(staticString: "https://api.notion.com/v1/search"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": "",
            "page_size": 50,
            "sort": ["direction": "descending", "timestamp": "last_edited_time"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.parseDestinations(data)
    }

    /// Parses a Notion `/v1/search` response into destinations. Databases carry
    /// their title at the top level; a page's title lives in whichever property
    /// has type `title` (its key is the column name, e.g. "Name", not literally
    /// "title"), which is why the old key-based lookup showed everything as
    /// "Untitled". Databases are sorted first, then alphabetically.
    static func parseDestinations(_ data: Data) throws -> [NotionDestination] {
        struct Inner: Decodable { let plain_text: String? }
        struct PageProperty: Decodable {
            let type: String?
            let title: [Inner]?
            enum CodingKeys: String, CodingKey { case type, title }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decodeIfPresent(String.self, forKey: .type)
                // A page's title property holds an array of rich text; a database's
                // title schema holds an object. Take the array, ignore anything else.
                title = try? c.decodeIfPresent([Inner].self, forKey: .title)
            }
        }
        struct Parent: Decodable { let type: String?; let page_id: String? }
        struct Icon: Decodable { let emoji: String? }
        struct Item: Decodable {
            let id: String
            let object: String  // "page" or "database"
            let properties: [String: PageProperty]?
            let parent: Parent?
            let icon: Icon?
            let title: [Inner]?  // databases ship their title at the top level
        }
        // Decode each result independently so one unexpected item can't fail the
        // whole response.
        struct Skippable: Decodable {
            let item: Item?
            init(from decoder: Decoder) throws { item = try? Item(from: decoder) }
        }
        struct SearchResponse: Decodable { let results: [Skippable] }

        let items = try JSONDecoder().decode(SearchResponse.self, from: data).results.compactMap(\.item)
        let known = Set(items.map(\.id))
        // Top-level only: keep all databases, plus pages at the workspace root or
        // the root of a shared subtree; drop pages nested under another shared
        // page and drop database rows. Trims the dropdown from every descendant
        // down to the handful you'd actually pick.
        func isTopLevel(_ item: Item) -> Bool {
            if item.object == "database" { return true }
            switch item.parent?.type {
            case "workspace":   return true
            case "database_id": return false
            case "page_id":     return !(item.parent?.page_id.map(known.contains) ?? false)
            default:            return true
            }
        }
        return items.filter(isTopLevel).map { item -> NotionDestination in
            let extractedTitle: String = {
                if let dbTitle = item.title?.compactMap(\.plain_text).joined(), !dbTitle.isEmpty {
                    return dbTitle
                }
                if let titleProp = item.properties?.values.first(where: { $0.type == "title" }),
                   let pageTitle = titleProp.title?.compactMap(\.plain_text).joined(), !pageTitle.isEmpty {
                    return pageTitle
                }
                return "Untitled"
            }()
            return NotionDestination(
                id: item.id,
                type: item.object == "database" ? .database : .page,
                title: extractedTitle,
                icon: item.icon?.emoji,
                parentPath: item.parent?.type
            )
        }
        .sorted { lhs, rhs in
            if (lhs.type == .database) != (rhs.type == .database) { return lhs.type == .database }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func databaseSchema(destinationId: String, workspaceId: String) async throws -> [NotionDatabaseProperty] {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(destinationId)") else {
            throw NotionError.from(status: 0, data: Data(), context: "invalid database id")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        struct DBResponse: Decodable {
            struct Property: Decodable {
                struct Option: Decodable { let name: String }
                struct OptionContainer: Decodable { let options: [Option] }
                let name: String
                let type: String
                let select: OptionContainer?
                let multi_select: OptionContainer?
                let status: OptionContainer?
            }
            let properties: [String: Property]
        }
        let parsed = try JSONDecoder().decode(DBResponse.self, from: data)
        return parsed.properties.map { (key, prop) -> NotionDatabaseProperty in
            let options = (prop.select?.options ?? prop.multi_select?.options ?? prop.status?.options ?? []).map(\.name)
            return NotionDatabaseProperty(name: key, type: prop.type, options: options)
        }
    }

    func createPage(workspaceId: String, destinationId: String, title: String) async throws -> NotionPageWriteResult {
        // The real write path lives in NotionDestinationClient. This entry
        // exists to satisfy the NotionClient protocol (used for previews and
        // legacy tests). It writes a minimal page.
        var request = URLRequest(url: URL(staticString: "https://api.notion.com/v1/pages"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "parent": ["page_id": destinationId],
            "properties": ["title": ["title": [["text": ["content": title]]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        struct PageResp: Decodable { let id: String; let url: String }
        let parsed = try JSONDecoder().decode(PageResp.self, from: data)
        return NotionPageWriteResult(id: parsed.id, url: parsed.url)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        throw NotionError.from(status: http.statusCode, data: data, context: "catalog request")
    }
}

