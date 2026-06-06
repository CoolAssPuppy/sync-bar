//
//  NotionTaskClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The Notion half of a two-way TaskSync. Distinct from NotionDestinationClient
//  (which writes transcribed reMarkable pages one-way): this reads database rows
//  AND creates/updates/archives them, projecting each row through the per-sync
//  TaskFieldMapping into the neutral CanonicalTask shape. Notion exposes only a
//  page-level `last_edited_time` (no per-field timing) — that's the conflict
//  tiebreak the coordinator uses, surfaced on every NotionRow.
//

import Foundation

/// Real Notion v2022-06-28 task client and the Notion `TaskProvider` conformer.
/// The granular `queryDatabase`/`createPage`/… methods stay (they're unit-tested
/// directly); the TaskProvider methods wrap them with the instance's config. The
/// field-shaping info lives in the mapping (captured from the schema in the
/// editor), so no per-call schema fetch is needed.
struct RealNotionTaskClient: TaskProvider {
    let token: String
    /// Present for the TaskProvider path (production); nil when constructed with
    /// just a token for direct method tests.
    let config: NotionTaskConfig?
    private let session: URLSession

    init(token: String, config: NotionTaskConfig? = nil, session: URLSession = .shared) {
        self.token = token
        self.config = config
        self.session = session
    }

    // MARK: TaskProvider (uses the instance's config)

    private func requireConfig() throws -> NotionTaskConfig {
        guard let config else { throw NotionError.validationFailed("Notion provider has no database configured.") }
        return config
    }

    func fetchTasks() async throws -> [RemoteTask] {
        let config = try requireConfig()
        return try await queryDatabase(databaseId: config.databaseId, mapping: config.fieldMapping)
    }
    func createTask(_ task: CanonicalTask) async throws -> String {
        let config = try requireConfig()
        return try await createPage(databaseId: config.databaseId, task: task, mapping: config.fieldMapping)
    }
    func updateTask(id: String, to task: CanonicalTask) async throws {
        let config = try requireConfig()
        try await updatePage(pageId: id, task: task, mapping: config.fieldMapping)
    }
    func removeTask(id: String) async throws {
        try await archivePage(pageId: id)
    }

    // MARK: Query (paginated)

    func queryDatabase(databaseId: String, mapping: TaskFieldMapping) async throws -> [RemoteTask] {
        var rows: [RemoteTask] = []
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            var request = try makeRequest(url: "https://api.notion.com/v1/databases/\(databaseId)/query",
                                          method: "POST")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data, context: "query database")
            let (pageRows, next) = try Self.parseQueryResponse(data: data, mapping: mapping)
            rows.append(contentsOf: pageRows)
            cursor = next
        } while cursor != nil
        return rows
    }

    // MARK: Create / update / archive

    func createPage(databaseId: String, task: CanonicalTask, mapping: TaskFieldMapping) async throws -> String {
        var request = try makeRequest(url: "https://api.notion.com/v1/pages", method: "POST")
        let body: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": Self.properties(for: task, mapping: mapping)
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data, context: "create task row")
        struct Page: Decodable { let id: String }
        return try JSONDecoder().decode(Page.self, from: data).id
    }

    func updatePage(pageId: String, task: CanonicalTask, mapping: TaskFieldMapping) async throws {
        var request = try makeRequest(url: "https://api.notion.com/v1/pages/\(pageId)", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": Self.properties(for: task, mapping: mapping)])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data, context: "update task row")
    }

    func archivePage(pageId: String) async throws {
        var request = try makeRequest(url: "https://api.notion.com/v1/pages/\(pageId)", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["archived": true])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data, context: "archive task row")
    }

    // MARK: Pure parsing (testable)

    /// Projects a `/databases/{id}/query` response into rows plus the next cursor
    /// (nil when there are no more pages).
    static func parseQueryResponse(data: Data, mapping: TaskFieldMapping) throws -> (rows: [RemoteTask], nextCursor: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw NotionError.validationFailed("Notion query response wasn't shaped as expected.")
        }
        let rows: [RemoteTask] = results.compactMap { result in
            guard let id = result["id"] as? String else { return nil }
            let props = result["properties"] as? [String: Any] ?? [:]
            let archived = result["archived"] as? Bool ?? false
            let lastEdited = parseDate(result["last_edited_time"]) ?? Date.distantPast
            let task = canonicalTask(fromProperties: props, mapping: mapping)
            return RemoteTask(id: id, task: task, lastEditedTime: lastEdited, archived: archived,
                              rawStatus: statusName(props: props, mapping: mapping))
        }
        let hasMore = root["has_more"] as? Bool ?? false
        let next = hasMore ? (root["next_cursor"] as? String) : nil
        return (rows, next)
    }

    /// Projects one row's `properties` object into a CanonicalTask through the
    /// mapping. Tolerant of missing/blank columns.
    static func canonicalTask(fromProperties props: [String: Any], mapping: TaskFieldMapping) -> CanonicalTask {
        let title = plainText(props[mapping.titleProperty], key: "title")
        let due = mapping.dueDateProperty.flatMap { dateValue(props[$0]) }
        let notes = mapping.notesProperty.map { plainText(props[$0], key: "rich_text") }
        let isCompleted = completion(props: props, mapping: mapping)
        let priority = mapping.priorityProperty.flatMap { priorityBucket(named: optionName(props[$0])) }
        let list = categoryName(props: props, mapping: mapping)
        return CanonicalTask(title: title,
                             due: due,
                             isCompleted: isCompleted,
                             notes: (notes?.isEmpty ?? true) ? nil : notes,
                             priority: priority,
                             list: list)
    }

    /// Normalizes a Notion select/status option to a Reminders priority bucket.
    /// Anything that isn't recognizably high/medium/low is left unmapped (nil) so
    /// we never overwrite a non-standard Notion priority.
    static func priorityBucket(named name: String?) -> String? {
        guard let n = name?.lowercased() else { return nil }
        if n.contains("high") { return "High" }
        if n.contains("medium") || n.contains("med") { return "Medium" }
        if n.contains("low") { return "Low" }
        return nil
    }

    /// The select/status option name on a property value.
    private static func optionName(_ property: Any?) -> String? {
        guard let value = property as? [String: Any] else { return nil }
        return (value["status"] as? [String: Any])?["name"] as? String
            ?? (value["select"] as? [String: Any])?["name"] as? String
    }

    /// The raw status/select option name on a row (not compared to any done
    /// value), used by filter rules. nil for a checkbox column or no status.
    static func statusName(props: [String: Any], mapping: TaskFieldMapping) -> String? {
        guard let name = mapping.statusProperty, let value = props[name] as? [String: Any] else { return nil }
        return (value["status"] as? [String: Any])?["name"] as? String
            ?? (value["select"] as? [String: Any])?["name"] as? String
    }

    /// The Reminders list name carried by a row's mapped "List" column. Reads
    /// whichever column type holds it: select/status (the option), multi_select
    /// (the first option), or rich_text. nil when the column is unmapped or empty.
    static func categoryName(props: [String: Any], mapping: TaskFieldMapping) -> String? {
        guard let name = mapping.categoryProperty, let value = props[name] as? [String: Any] else { return nil }
        if let option = (value["status"] as? [String: Any])?["name"] as? String { return option }
        if let option = (value["select"] as? [String: Any])?["name"] as? String { return option }
        if let multi = value["multi_select"] as? [[String: Any]] {
            return multi.compactMap { $0["name"] as? String }.first
        }
        if let runs = value["rich_text"] as? [[String: Any]] {
            let text = runs.compactMap { ($0["plain_text"] as? String) ?? ($0["text"] as? [String: Any])?["content"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Reads completion from the status column, robust to whichever shape it has
    /// (checkbox bool, or a status/select option compared to the "done" value).
    private static func completion(props: [String: Any], mapping: TaskFieldMapping) -> Bool {
        guard let name = mapping.statusProperty, let value = props[name] as? [String: Any] else { return false }
        if let checkbox = value["checkbox"] as? Bool { return checkbox }
        let optionName = (value["status"] as? [String: Any])?["name"] as? String
            ?? (value["select"] as? [String: Any])?["name"] as? String
        guard let optionName, let done = mapping.statusDoneValue else { return false }
        return optionName.caseInsensitiveCompare(done) == .orderedSame
    }

    /// Joins a title / rich_text property's text runs into a plain string.
    private static func plainText(_ property: Any?, key: String) -> String {
        guard let property = property as? [String: Any],
              let runs = property[key] as? [[String: Any]] else { return "" }
        return runs.compactMap { run -> String? in
            if let plain = run["plain_text"] as? String { return plain }
            return (run["text"] as? [String: Any])?["content"] as? String
        }.joined()
    }

    /// A date property's `start` → a Date at day granularity.
    private static func dateValue(_ property: Any?) -> Date? {
        guard let property = property as? [String: Any],
              let date = property["date"] as? [String: Any] else { return nil }
        return parseDate(date["start"])
    }

    /// Parses a Notion timestamp: a bare "yyyy-MM-dd" date or a full ISO 8601
    /// instant. Returns nil for anything else.
    static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        if string.count == 10 {  // "yyyy-MM-dd"
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: string) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    // MARK: Pure encoding (testable)

    /// Builds the `properties` payload for a create/update from a task, shaped to
    /// each column's type via the mapping. A nil due clears the date; nil notes
    /// clears the text; completion is shaped per `statusPropertyType`; the list
    /// name fills the mapped "List" column.
    static func properties(for task: CanonicalTask, mapping: TaskFieldMapping) -> [String: Any] {
        var properties: [String: Any] = [
            mapping.titleProperty: ["title": [["text": ["content": task.title]]]]
        ]

        if let dueProperty = mapping.dueDateProperty {
            if let due = task.due {
                properties[dueProperty] = ["date": ["start": dayString(due)]]
            } else {
                properties[dueProperty] = ["date": NSNull()]
            }
        }

        if let notesProperty = mapping.notesProperty {
            let notes = task.notes ?? ""
            properties[notesProperty] = ["rich_text": notes.isEmpty ? [] : [["text": ["content": notes]]]]
        }

        if let statusProperty = mapping.statusProperty, let value = statusValue(for: task, mapping: mapping) {
            properties[statusProperty] = value
        }

        // Only write priority when we have one — a nil priority leaves Notion's
        // value untouched (so non-standard priorities aren't wiped).
        if let priorityProperty = mapping.priorityProperty, let bucket = task.priority {
            let key = mapping.priorityPropertyType == "status" ? "status" : "select"
            properties[priorityProperty] = [key: ["name": bucket]]
        }

        // Write the task's Reminders list name into the mapped column, shaped to
        // the column type. List membership is bidirectional, so this writes on
        // creates and updates alike. Notion creates a select/multi-select option
        // if it doesn't exist yet. A nil list (no list column mapped) is skipped.
        if let categoryProperty = mapping.categoryProperty, let value = task.list, !value.isEmpty {
            switch mapping.categoryPropertyType {
            case "multi_select": properties[categoryProperty] = ["multi_select": [["name": value]]]
            case "rich_text":    properties[categoryProperty] = ["rich_text": [["text": ["content": value]]]]
            case "status":       properties[categoryProperty] = ["status": ["name": value]]
            default:             properties[categoryProperty] = ["select": ["name": value]]
            }
        }

        return properties
    }

    /// The status column payload for a task's completion, or nil to leave the
    /// column untouched (an incomplete task with no configured "not done" option).
    private static func statusValue(for task: CanonicalTask, mapping: TaskFieldMapping) -> [String: Any]? {
        switch mapping.statusPropertyType {
        case "checkbox":
            return ["checkbox": task.isCompleted]
        case "status", "select":
            let key = mapping.statusPropertyType!  // "status" or "select"
            let optionName = task.isCompleted ? mapping.statusDoneValue : mapping.statusNotDoneValue
            guard let optionName, !optionName.isEmpty else { return nil }
            return [key: ["name": optionName]]
        default:
            return nil
        }
    }

    /// A Date → "yyyy-MM-dd" so both sides stay at day granularity.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: Request plumbing

    private func makeRequest(url: String, method: String) throws -> URLRequest {
        try Self.request(url: url, method: method, token: token)
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
