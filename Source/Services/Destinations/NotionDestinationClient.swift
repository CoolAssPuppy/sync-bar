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

    func write(payload: DestinationPayload, configuration: DestinationConfiguration, existingExternalId: String?) async throws -> DestinationWriteResult {
        guard case .notion(let config) = configuration else {
            throw DestinationError.wrongConfiguration(expected: .notion)
        }
        if let token = KeychainStore.shared.value(for: .notionWorkspaceToken(workspaceId: config.workspaceId)),
           !token.isEmpty {
            return try await writeWithRealNotion(token: token, config: config, payload: payload, existingId: existingExternalId)
        }
        return try await writeWithMock(config: config, payload: payload, existingId: existingExternalId)
    }

    // MARK: Real Notion (v2022-06-28)

    private func writeWithRealNotion(token: String, config: NotionDestinationConfig, payload: DestinationPayload, existingId: String?) async throws -> DestinationWriteResult {
        let properties = try await buildProperties(token: token, config: config, payload: payload)
        let children = Self.buildChildren(payload: payload)
        // Update in place when we've synced this note before, so an edit updates
        // the same page/row instead of creating a duplicate.
        if let pageId = existingId, !pageId.isEmpty {
            return try await updatePage(token: token, pageId: pageId, properties: properties, children: children)
        }
        return try await createPage(token: token, config: config, properties: properties, children: children)
    }

    /// Title + mapped column values, shaped to the database's live schema.
    private func buildProperties(token: String, config: NotionDestinationConfig, payload: DestinationPayload) async throws -> [String: Any] {
        switch config.destinationType {
        case .page:
            return ["title": ["title": [["text": ["content": payload.title]]]]]
        case .database:
            // Look up the live schema so we can (a) write the title under its
            // real property name and (b) shape each mapped value to the column's
            // actual type. Notion rejects a value whose shape doesn't match the
            // column (e.g. a select payload for a multi_select column).
            let schema = try await RealNotionClient(token: token)
                .databaseSchema(destinationId: config.destinationId, workspaceId: config.workspaceId)
            let typeByName = Dictionary(schema.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
            let titleName = schema.first(where: { $0.type == "title" })?.name ?? "Name"
            var properties: [String: Any] = [titleName: ["title": [["text": ["content": payload.title]]]]]
            for (columnName, mapping) in config.propertyMappings where columnName != titleName {
                guard let columnType = typeByName[columnName] else { continue }
                if let value = Self.propertyValue(for: mapping, columnType: columnType, payload: payload) {
                    properties[columnName] = value
                }
            }
            return properties
        }
    }

    /// Builds the page body. Renders structured blocks natively (headings,
    /// bulleted lists, to-do checkboxes, Mermaid code); falls back to splitting
    /// `body` into paragraphs for any payload that has no blocks.
    static func buildChildren(payload: DestinationPayload) -> [[String: Any]] {
        guard !payload.blocks.isEmpty else { return bodyParagraphs(payload: payload) }
        return payload.blocks.map(notionBlock(for:))
    }

    /// Legacy path: split the flattened body on blank lines into paragraphs,
    /// then append any Mermaid diagram as a code block.
    private static func bodyParagraphs(payload: DestinationPayload) -> [[String: Any]] {
        var children: [[String: Any]] = []
        for paragraph in payload.body.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": ["rich_text": richText(paragraph)]
            ])
        }
        if let mermaid = payload.mermaidSource {
            children.append(mermaidBlock(mermaid))
        }
        return children
    }

    /// Maps one `NoteBlock` to its Notion block JSON.
    private static func notionBlock(for block: NoteBlock) -> [String: Any] {
        switch block {
        case .heading(let text):
            return ["object": "block", "type": "heading_2",
                    "heading_2": ["rich_text": richText(text)]]
        case .paragraph(let text):
            return ["object": "block", "type": "paragraph",
                    "paragraph": ["rich_text": richText(text)]]
        case .bullet(let text):
            return ["object": "block", "type": "bulleted_list_item",
                    "bulleted_list_item": ["rich_text": richText(text)]]
        case .checkbox(let text, let checked):
            return ["object": "block", "type": "to_do",
                    "to_do": ["rich_text": richText(text), "checked": checked]]
        case .mermaid(let source):
            return mermaidBlock(source)
        }
    }

    private static func mermaidBlock(_ source: String) -> [String: Any] {
        ["object": "block", "type": "code",
         "code": ["language": "mermaid", "rich_text": richText(source)]]
    }

    /// Notion caps a single rich_text content string at 2000 characters, so
    /// long text is split across several text objects in the same block.
    private static func richText(_ text: String) -> [[String: Any]] {
        guard !text.isEmpty else { return [] }
        let limit = 2000
        var objects: [[String: Any]] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            objects.append(["type": "text", "text": ["content": String(text[index..<end])]])
            index = end
        }
        return objects
    }

    /// Splits blocks into batches of at most `size`, since Notion accepts at
    /// most 100 children per create or append request.
    static func chunked(_ blocks: [[String: Any]], size: Int = 100) -> [[[String: Any]]] {
        guard size > 0, blocks.count > size else { return blocks.isEmpty ? [] : [blocks] }
        return stride(from: 0, to: blocks.count, by: size).map {
            Array(blocks[$0..<min($0 + size, blocks.count)])
        }
    }

    private func createPage(token: String, config: NotionDestinationConfig, properties: [String: Any], children: [[String: Any]]) async throws -> DestinationWriteResult {
        let parent: [String: Any] = config.destinationType == .database
            ? ["database_id": config.destinationId]
            : ["page_id": config.destinationId]
        // Notion accepts at most 100 children in the create call; the page is
        // created with the first batch and the rest are appended afterwards.
        let initial = Array(children.prefix(100))
        var request = try Self.notionRequest(url: "https://api.notion.com/v1/pages", method: "POST", token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["parent": parent, "properties": properties, "children": initial])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NotionError.from(status: http.statusCode, data: data, context: "create \(config.destinationType == .database ? "database row" : "page")")
        }
        struct Page: Decodable { let id: String; let url: String }
        let parsed = try JSONDecoder().decode(Page.self, from: data)
        if children.count > 100 {
            try await appendChildren(token: token, pageId: parsed.id, children: Array(children.dropFirst(100)))
        }
        return DestinationWriteResult(externalId: parsed.id, externalURL: URL(string: parsed.url), notes: nil)
    }

    /// Updates an existing page's properties, then replaces its body blocks so
    /// the content reflects the edited note.
    private func updatePage(token: String, pageId: String, properties: [String: Any], children: [[String: Any]]) async throws -> DestinationWriteResult {
        var request = try Self.notionRequest(url: "https://api.notion.com/v1/pages/\(pageId)", method: "PATCH", token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NotionError.from(status: http.statusCode, data: data, context: "update page")
        }
        try await replaceChildren(token: token, pageId: pageId, children: children)

        struct Page: Decodable { let id: String; let url: String }
        let parsed = try JSONDecoder().decode(Page.self, from: data)
        return DestinationWriteResult(externalId: parsed.id, externalURL: URL(string: parsed.url), notes: nil)
    }

    /// Archives the page's current top-level blocks and appends the fresh ones.
    private func replaceChildren(token: String, pageId: String, children: [[String: Any]]) async throws {
        // List existing children (notes are small; one page of 100 is plenty).
        var listRequest = try Self.notionRequest(url: "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100", method: "GET", token: token)
        listRequest.httpBody = nil
        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        if let http = listResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NotionError.from(status: http.statusCode, data: listData, context: "list page blocks")
        }
        struct BlockList: Decodable { struct Block: Decodable { let id: String }; let results: [Block] }
        let existing = (try? JSONDecoder().decode(BlockList.self, from: listData))?.results ?? []

        for block in existing {
            let deleteRequest = try Self.notionRequest(url: "https://api.notion.com/v1/blocks/\(block.id)", method: "DELETE", token: token)
            let (delData, delResponse) = try await URLSession.shared.data(for: deleteRequest)
            if let http = delResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NotionError.from(status: http.statusCode, data: delData, context: "delete page block")
            }
        }

        try await appendChildren(token: token, pageId: pageId, children: children)
    }

    /// Appends blocks to a page in batches of 100 (Notion's per-request cap).
    private func appendChildren(token: String, pageId: String, children: [[String: Any]]) async throws {
        for batch in Self.chunked(children) {
            var request = try Self.notionRequest(url: "https://api.notion.com/v1/blocks/\(pageId)/children", method: "PATCH", token: token)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["children": batch])
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NotionError.from(status: http.statusCode, data: data, context: "append page blocks")
            }
        }
    }

    private static func notionRequest(url: String, method: String, token: String) throws -> URLRequest {
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

    // MARK: Property mapping → Notion JSON

    /// Translates one `NotionPropertyMapping` into the Notion v2022-06-28
    /// `properties[name] = …` payload, shaped to the *column's actual type*
    /// (`columnType` from the live schema). The mapping supplies the value; the
    /// column type decides the wrapper. Returns nil to leave the column blank
    /// (e.g. `.leaveBlank`, an unsupported column type, or an empty value).
    static func propertyValue(for mapping: NotionPropertyMapping,
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
                    title: payload.title,
                    folderName: payload.folderName,
                    metadata: payload.metadata,
                    body: payload.body
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
            // Chunked through richText so a value past Notion's 2000-char
            // per-object cap (a full tweet thread) splits instead of 400ing.
            // Notion also caps a property at ~25 objects; beyond that it
            // truncates server-side, which is acceptable.
            let value = resolvedString()
            return value.isEmpty ? nil : ["rich_text": richText(value)]
        case "select":
            guard let name = optionNames().first else { return nil }
            return ["select": ["name": name]]
        case "status":
            guard let name = optionNames().first else { return nil }
            return ["status": ["name": name]]
        case "multi_select":
            // Notion forbids commas in option names; a comma-joined value means
            // several options, so split and trim into discrete ones.
            let names = optionNames()
                .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                .filter { !$0.isEmpty }
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

    private func writeWithMock(config: NotionDestinationConfig, payload: DestinationPayload, existingId: String?) async throws -> DestinationWriteResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = existingId ?? ("p-" + UUID().uuidString.prefix(10).lowercased())
        return DestinationWriteResult(
            externalId: id,
            externalURL: URL(string: "https://www.notion.so/preview/\(id)"),
            notes: "Mock Notion write (no token configured)."
        )
    }
}
