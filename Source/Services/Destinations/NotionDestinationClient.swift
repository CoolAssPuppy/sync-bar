//
//  NotionDestinationClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

/// Writes a transcribed page into Notion as either a child page (when the
/// destination is a Notion page) or a row (when it's a database).
///
/// If a Notion workspace access token is in `KeychainStore`, the client
/// calls the real Notion v2022-06-28 API. Without a token it falls back
/// to the deterministic mock so the UI is exercisable end-to-end.
struct NotionDestinationClient: DestinationClient {
    let kind: DestinationKind = .notion

    func write(payload: DestinationPayload, configuration: DestinationConfiguration) async throws -> DestinationWriteResult {
        guard case .notion(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .notion)
        }
        if let token = KeychainStore.shared.value(for: .notionWorkspaceToken(workspaceId: config.workspaceId)),
           !token.isEmpty {
            return try await writeWithRealNotion(token: token, config: config, payload: payload)
        }
        return try await writeWithMock(config: config, payload: payload)
    }

    // MARK: Real Notion (v2022-06-28)

    private func writeWithRealNotion(token: String, config: NotionDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parent: [String: Any] = [:]
        var properties: [String: Any] = [:]
        switch config.destinationType {
        case .page:
            parent = ["page_id": config.destinationId]
            properties = ["title": ["title": [["text": ["content": payload.title]]]]]
        case .database:
            parent = ["database_id": config.destinationId]
            // Look up the live schema so we can (a) write the title under its
            // real property name and (b) shape each mapped value to the column's
            // actual type. Notion rejects a value whose shape doesn't match the
            // column (e.g. a select payload for a multi_select column).
            let schema = try await RealNotionClient(token: token)
                .databaseSchema(destinationId: config.destinationId, workspaceId: config.workspaceId)
            let typeByName = Dictionary(schema.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
            let titleName = schema.first(where: { $0.type == "title" })?.name ?? "Name"
            properties[titleName] = ["title": [["text": ["content": payload.title]]]]
            for (columnName, mapping) in config.propertyMappings where columnName != titleName {
                guard let columnType = typeByName[columnName] else { continue }
                if let value = Self.propertyValue(for: mapping, columnType: columnType, payload: payload) {
                    properties[columnName] = value
                }
            }
        }

        var children: [[String: Any]] = []
        for paragraph in payload.body.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["type": "text", "text": ["content": paragraph]]]
                ]
            ])
        }
        if let mermaid = payload.mermaidSource {
            children.append([
                "object": "block",
                "type": "code",
                "code": [
                    "language": "mermaid",
                    "rich_text": [["type": "text", "text": ["content": mermaid]]]
                ]
            ])
        }

        let body: [String: Any] = ["parent": parent, "properties": properties, "children": children]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NotionError.from(status: http.statusCode, data: data, context: "create \(config.destinationType == .database ? "database row" : "page")")
        }

        struct Page: Decodable { let id: String; let url: String }
        let parsed = try JSONDecoder().decode(Page.self, from: data)
        return DestinationWriteResult(externalId: parsed.id, externalURL: URL(string: parsed.url), notes: nil)
    }

    // MARK: Property mapping → Notion JSON

    /// Translates one `NotionPropertyMapping` into the Notion v2022-06-28
    /// `properties[name] = …` payload, shaped to the *column's actual type*
    /// (`columnType` from the live schema). The mapping supplies the value; the
    /// column type decides the wrapper. Returns nil to leave the column blank
    /// (e.g. `.leaveBlank`, an unsupported column type, or an empty value).
    private static func propertyValue(for mapping: NotionPropertyMapping,
                                      columnType: String,
                                      payload: DestinationPayload) -> [String: Any]? {
        if case .leaveBlank = mapping { return nil }

        // A single text value derived from whatever the mapping carries.
        func resolvedString() -> String {
            switch mapping {
            case .text(let template):
                let context = TitleTemplateContext(
                    notebook: payload.ruleNotebookName,
                    pageNumber: payload.pageNumber,
                    date: payload.sourceDate,
                    title: payload.title
                )
                return context.apply(to: template)
            case .literal(let value):            return value
            case .selectOption(let name):        return name
            case .multiSelectOptions(let names): return names.joined(separator: ", ")
            case .number(let value):             return String(value)
            case .checkbox(let value):           return value ? "true" : "false"
            case .dateSource, .leaveBlank:       return ""
            }
        }

        // Option name(s) for select / multi_select / status columns.
        func optionNames() -> [String] {
            switch mapping {
            case .selectOption(let name):        return name.isEmpty ? [] : [name]
            case .multiSelectOptions(let names): return names.filter { !$0.isEmpty }
            case .text, .literal:
                let value = resolvedString()
                return value.isEmpty ? [] : [value]
            default:                             return []
            }
        }

        // A date for date columns: "today" maps to the sync date, otherwise the
        // page's own date. (Idempotency only re-creates a row when the page
        // changes, so a "today" value is captured once and never rewritten.)
        func resolvedDate() -> Date {
            if case .dateSource(let source) = mapping {
                switch source {
                case .pageCreated, .pageModified: return payload.sourceDate
                case .syncedAt:                   return Date()
                }
            }
            if case .text(let template) = mapping, template.contains("{today}") {
                return Date()
            }
            return payload.sourceDate
        }

        switch columnType {
        case "title":
            return nil  // written by the caller under the real title property
        case "rich_text":
            let value = resolvedString()
            return value.isEmpty ? nil : ["rich_text": [["type": "text", "text": ["content": value]]]]
        case "select":
            guard let name = optionNames().first else { return nil }
            return ["select": ["name": name]]
        case "status":
            guard let name = optionNames().first else { return nil }
            return ["status": ["name": name]]
        case "multi_select":
            let names = optionNames()
            return names.isEmpty ? nil : ["multi_select": names.map { ["name": $0] }]
        case "date":
            return ["date": ["start": ISO8601DateFormatter().string(from: resolvedDate())]]
        case "checkbox":
            if case .checkbox(let value) = mapping { return ["checkbox": value] }
            return ["checkbox": resolvedString().lowercased() == "true"]
        case "number":
            if case .number(let value) = mapping { return ["number": value] }
            guard let parsed = Double(resolvedString()) else { return nil }
            return ["number": parsed]
        case "url":
            let value = resolvedString(); return value.isEmpty ? nil : ["url": value]
        case "email":
            let value = resolvedString(); return value.isEmpty ? nil : ["email": value]
        case "phone_number":
            let value = resolvedString(); return value.isEmpty ? nil : ["phone_number": value]
        default:
            // people, relation, files, formula, rollup, created_time, … can't
            // be populated from a transcribed page; leave them untouched.
            return nil
        }
    }

    // MARK: Mock fallback

    private func writeWithMock(config: NotionDestinationConfig, payload: DestinationPayload) async throws -> DestinationWriteResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = "p-" + UUID().uuidString.prefix(10).lowercased()
        return DestinationWriteResult(
            externalId: id,
            externalURL: URL(string: "https://www.notion.so/preview/\(id)"),
            notes: "Mock Notion write (no token configured)."
        )
    }
}
