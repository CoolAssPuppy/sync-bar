//
//  NotionBlockConverter.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Pure mapping from one Notion block (the JSON object the blocks API returns)
//  to zero or more `NoteBlock`s — the neutral seam every destination consumes.
//  Notion has dozens of block types; we collapse them onto the five NoteBlock
//  cases (heading / paragraph / bullet / checkbox / mermaid), which is exactly
//  the fidelity Apple Notes and Markdown can carry anyway. A fenced code block
//  tagged `mermaid` is the one structural promotion (to `.mermaid`); everything
//  else degrades to text. Nesting is flattened: a child block is converted on
//  its own and appended after its parent (see NotionPageReader's recursion).
//

import Foundation

enum NotionBlockConverter {

    /// Converts one Notion block object into the NoteBlocks it represents. An
    /// empty array means "nothing to render" (dividers, unsupported types, blank
    /// paragraphs) — the caller still recurses into any children separately.
    static func convert(_ block: [String: Any]) -> [NoteBlock] {
        guard let type = block["type"] as? String else { return [] }
        let payload = block[type] as? [String: Any] ?? [:]

        switch type {
        case "heading_1", "heading_2", "heading_3":
            let text = richText(payload)
            return text.isEmpty ? [] : [.heading(text)]

        case "paragraph", "quote", "callout", "toggle":
            // Toggle/quote/callout summary text becomes a paragraph; their
            // children are appended by the reader's recursion.
            let text = richText(payload)
            return text.isEmpty ? [] : [.paragraph(text)]

        case "bulleted_list_item", "numbered_list_item":
            let text = richText(payload)
            return text.isEmpty ? [] : [.bullet(text)]

        case "to_do":
            let text = richText(payload)
            let checked = payload["checked"] as? Bool ?? false
            return text.isEmpty ? [] : [.checkbox(text: text, checked: checked)]

        case "code":
            let text = richText(payload)
            if text.isEmpty { return [] }
            let language = (payload["language"] as? String)?.lowercased()
            if language == "mermaid" { return [.mermaid(text)] }
            return [.paragraph(text)]

        case "divider", "table_of_contents", "breadcrumb", "child_page",
             "child_database", "unsupported", "synced_block", "column_list",
             "column", "table", "table_row":
            // Structural/containers with no text of their own (children, if any,
            // are recursed into) or types we can't faithfully represent.
            return []

        default:
            // Best effort for any other text-bearing block.
            let text = richText(payload)
            return text.isEmpty ? [] : [.paragraph(text)]
        }
    }

    /// True for block types whose children carry note content worth recursing
    /// into (toggles, list items with nested items, quotes, callouts, columns).
    /// Child pages/databases are deliberately excluded — a backup of one database
    /// shouldn't pull in linked subtrees.
    static func recursesIntoChildren(_ block: [String: Any]) -> Bool {
        guard block["has_children"] as? Bool == true,
              let type = block["type"] as? String else { return false }
        switch type {
        case "child_page", "child_database", "synced_block":
            return false
        default:
            return true
        }
    }

    /// Joins the `rich_text` run array on a block payload into a plain string.
    /// Notion ships each run's resolved text in `plain_text`; we fall back to the
    /// nested `text.content` when an older shape omits it.
    static func richText(_ payload: [String: Any]) -> String {
        guard let runs = payload["rich_text"] as? [[String: Any]] else { return "" }
        return runs.compactMap { run -> String? in
            if let plain = run["plain_text"] as? String { return plain }
            return (run["text"] as? [String: Any])?["content"] as? String
        }.joined()
    }
}
