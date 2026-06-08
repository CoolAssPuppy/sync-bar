//
//  NotionPageReader.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The read half of Notion-as-a-source. Mirrors RealNotionTaskClient's plumbing
//  (token + URLSession, pure parse statics) but for note backup rather than
//  tasks: it lists a database's rows as lightweight page summaries (id, title,
//  Category, created/edited timestamps) and fetches one page's block tree as
//  `[NoteBlock]`. Pagination and the optional incremental `last_edited_time`
//  filter live here; the block shaping lives in NotionBlockConverter.
//

import Foundation

struct NotionPageReader: Sendable {
    let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// One database row, reduced to what the source pipeline needs. `category` is
    /// the value of the configured single-select column (nil when blank), used as
    /// the destination folder. `createdAt` preserves the original note date (it
    /// mirrors the page's created_time, which the user set to the pre-Notion date
    /// when migrating from Apple Notes).
    struct PageSummary: Sendable, Equatable {
        var id: String
        var title: String
        var category: String?
        var createdAt: Date
        var lastEditedTime: Date
        /// Every column value, serialized to a readable string, for frontmatter.
        var properties: [String: String] = [:]
    }

    /// Max nesting depth we recurse for a page's block tree, a guard against
    /// pathological documents. Two levels covers ordinary nested lists/toggles.
    private static let maxBlockDepth = 4
    private static let pageSize = 100

    // MARK: Query (paginated, optionally incremental)

    /// Every row in the database as a page summary. When `sinceLastEdited` is set,
    /// only rows edited on or after it are returned (Notion's `last_edited_time`
    /// filter) — the cheap-fetch path for incremental runs.
    func queryPages(databaseId: String,
                    titleProperty: String,
                    categoryProperty: String,
                    dateProperty: String = "",
                    sinceLastEdited: Date? = nil) async throws -> [PageSummary] {
        var pages: [PageSummary] = []
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": Self.pageSize]
            if let cursor { body["start_cursor"] = cursor }
            if let sinceLastEdited {
                body["filter"] = [
                    "timestamp": "last_edited_time",
                    "last_edited_time": ["on_or_after": Self.isoString(sinceLastEdited)]
                ]
            }
            var request = try Self.request(url: "https://api.notion.com/v1/databases/\(databaseId)/query",
                                            method: "POST", token: token)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data, context: "query notion database")
            let (rows, next) = try Self.parsePageSummaries(data: data,
                                                           titleProperty: titleProperty,
                                                           categoryProperty: categoryProperty,
                                                           dateProperty: dateProperty)
            pages.append(contentsOf: rows)
            cursor = next
        } while cursor != nil
        return pages
    }

    // MARK: Blocks

    /// One page's content as a flat ordered list of NoteBlocks. Fetches block
    /// children (paginated) and recurses into containers (toggles, nested lists)
    /// up to `maxBlockDepth`, converting each block via NotionBlockConverter.
    func pageBlocks(pageId: String) async throws -> [NoteBlock] {
        try await blocks(of: pageId, depth: 0)
    }

    private func blocks(of blockId: String, depth: Int) async throws -> [NoteBlock] {
        guard depth < Self.maxBlockDepth else { return [] }
        var result: [NoteBlock] = []
        var cursor: String? = nil
        repeat {
            var url = "https://api.notion.com/v1/blocks/\(blockId)/children?page_size=\(Self.pageSize)"
            if let cursor { url += "&start_cursor=\(cursor)" }
            let request = try Self.request(url: url, method: "GET", token: token)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data, context: "fetch notion blocks")
            let (rawBlocks, next) = try Self.parseBlockObjects(data: data)
            for block in rawBlocks {
                result.append(contentsOf: NotionBlockConverter.convert(block))
                if NotionBlockConverter.recursesIntoChildren(block),
                   let childId = block["id"] as? String {
                    result.append(contentsOf: try await blocks(of: childId, depth: depth + 1))
                }
            }
            cursor = next
        } while cursor != nil
        return result
    }

    // MARK: Pure parsing (testable)

    /// Projects a `/databases/{id}/query` response into page summaries plus the
    /// next cursor. Tolerant of rows missing the title or category column.
    static func parsePageSummaries(data: Data,
                                   titleProperty: String,
                                   categoryProperty: String,
                                   dateProperty: String = "") throws -> (pages: [PageSummary], nextCursor: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw NotionError.validationFailed("Notion query response wasn't shaped as expected.")
        }
        let pages: [PageSummary] = results.compactMap { result in
            guard let id = result["id"] as? String else { return nil }
            let props = result["properties"] as? [String: Any] ?? [:]
            let createdTime = RealNotionTaskClient.parseDate(result["created_time"]) ?? Date.distantPast
            let edited = RealNotionTaskClient.parseDate(result["last_edited_time"]) ?? createdTime
            // The note's date comes from the configured date column when set (e.g.
            // "Created Date" holding the original date), falling back to created_time.
            let created = (dateProperty.isEmpty ? nil : dateValue(props[dateProperty])) ?? createdTime
            return PageSummary(
                id: id,
                title: title(props: props, preferred: titleProperty),
                category: selectName(props[categoryProperty]),
                createdAt: created,
                lastEditedTime: edited,
                properties: serializeProperties(props)
            )
        }
        let hasMore = root["has_more"] as? Bool ?? false
        let next = hasMore ? (root["next_cursor"] as? String) : nil
        return (pages, next)
    }

    /// Serializes every column value to a readable string for frontmatter. Covers
    /// the common Notion property types; unknown/empty ones are skipped.
    static func serializeProperties(_ props: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, raw) in props {
            guard let value = raw as? [String: Any], let type = value["type"] as? String else { continue }
            let string: String?
            switch type {
            case "title", "rich_text":
                string = richTextString(value[type])
            case "select":
                string = (value["select"] as? [String: Any])?["name"] as? String
            case "status":
                string = (value["status"] as? [String: Any])?["name"] as? String
            case "multi_select":
                string = (value["multi_select"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
            case "date":
                string = (value["date"] as? [String: Any])?["start"] as? String
            case "number":
                string = (value["number"] as? NSNumber)?.stringValue
            case "checkbox":
                string = (value["checkbox"] as? Bool).map { $0 ? "true" : "false" }
            case "url", "email", "phone_number":
                string = value[type] as? String
            case "people":
                string = (value["people"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
            case "created_time", "last_edited_time":
                string = value[type] as? String
            case "formula":
                let f = value["formula"] as? [String: Any]
                string = (f?["string"] as? String) ?? (f?["number"] as? NSNumber)?.stringValue ?? (f?["boolean"] as? Bool).map { $0 ? "true" : "false" }
            default:
                string = nil
            }
            if let string, !string.isEmpty { out[name] = string }
        }
        return out
    }

    private static func richTextString(_ value: Any?) -> String? {
        guard let runs = value as? [[String: Any]] else { return nil }
        let text = runs.compactMap { ($0["plain_text"] as? String) ?? ($0["text"] as? [String: Any])?["content"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// A date property's `start` → a Date (day or instant).
    private static func dateValue(_ property: Any?) -> Date? {
        guard let property = property as? [String: Any],
              let date = property["date"] as? [String: Any] else { return nil }
        return RealNotionTaskClient.parseDate(date["start"])
    }

    /// Extracts the block objects array and the next cursor from a
    /// `/blocks/{id}/children` response.
    static func parseBlockObjects(data: Data) throws -> (blocks: [[String: Any]], nextCursor: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw NotionError.validationFailed("Notion blocks response wasn't shaped as expected.")
        }
        let hasMore = root["has_more"] as? Bool ?? false
        let next = hasMore ? (root["next_cursor"] as? String) : nil
        return (results, next)
    }

    /// The page title from the preferred column, falling back to whichever
    /// property is of type `title` (a database's title column name varies).
    static func title(props: [String: Any], preferred: String) -> String {
        if !preferred.isEmpty, let value = titleText(props[preferred]), !value.isEmpty {
            return value
        }
        for (_, value) in props {
            if let dict = value as? [String: Any], dict["type"] as? String == "title",
               let text = titleText(dict), !text.isEmpty {
                return text
            }
        }
        return "Untitled"
    }

    /// Joins a title property's text runs into a plain string.
    private static func titleText(_ property: Any?) -> String? {
        guard let property = property as? [String: Any],
              let runs = property["title"] as? [[String: Any]] else { return nil }
        let text = runs.compactMap { run -> String? in
            if let plain = run["plain_text"] as? String { return plain }
            return (run["text"] as? [String: Any])?["content"] as? String
        }.joined()
        return text.isEmpty ? nil : text
    }

    /// The chosen option name of a select/status column (the Category value), or
    /// the first option of a multi-select. nil when blank or a non-option type.
    static func selectName(_ property: Any?) -> String? {
        guard let value = property as? [String: Any] else { return nil }
        if let name = (value["select"] as? [String: Any])?["name"] as? String { return name }
        if let name = (value["status"] as? [String: Any])?["name"] as? String { return name }
        if let multi = value["multi_select"] as? [[String: Any]] {
            return multi.compactMap { $0["name"] as? String }.first
        }
        return nil
    }

    // MARK: Request plumbing

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func request(url: String, method: String, token: String) throws -> URLRequest {
        guard let parsed = URL(string: url) else {
            throw NotionError.from(status: 0, data: Data(), context: "invalid Notion URL")
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func validate(response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        throw NotionError.from(status: http.statusCode, data: data, context: context)
    }
}
