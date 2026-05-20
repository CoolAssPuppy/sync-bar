//
//  FieldMappingControl.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// What a mapped destination column is filled with. The presets resolve to
/// reMarkable note fields (via title-template tokens); `.custom` is free text
/// that may itself contain tokens.
enum NoteFieldValue: Equatable, Hashable {
    case noteTitle
    case notebookName
    case pageNumber
    case pageDate
    case todaysDate
    case custom(String)

    var kind: NoteFieldKind {
        switch self {
        case .noteTitle:    return .noteTitle
        case .notebookName: return .notebookName
        case .pageNumber:   return .pageNumber
        case .pageDate:     return .pageDate
        case .todaysDate:   return .todaysDate
        case .custom:       return .custom
        }
    }

    var customText: String {
        if case .custom(let text) = self { return text }
        return ""
    }

    /// The title-template token (or literal custom text) this value resolves to.
    var token: String {
        switch self {
        case .noteTitle:        return "{title}"
        case .notebookName:     return "{notebook}"
        case .pageNumber:       return "{page_n}"
        case .pageDate:         return "{date}"
        case .todaysDate:       return "{today}"
        case .custom(let text): return text
        }
    }

    init(token: String) {
        switch token {
        case "{title}":    self = .noteTitle
        case "{notebook}": self = .notebookName
        case "{page_n}":   self = .pageNumber
        case "{date}":     self = .pageDate
        case "{today}":    self = .todaysDate
        default:           self = .custom(token)
        }
    }

    static func make(kind: NoteFieldKind, custom: String) -> NoteFieldValue {
        switch kind {
        case .noteTitle:    return .noteTitle
        case .notebookName: return .notebookName
        case .pageNumber:   return .pageNumber
        case .pageDate:     return .pageDate
        case .todaysDate:   return .todaysDate
        case .custom:       return .custom(custom)
        }
    }
}

enum NoteFieldKind: String, CaseIterable, Identifiable {
    case noteTitle
    case notebookName
    case pageNumber
    case pageDate
    case todaysDate
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .noteTitle:    return "Title of note"
        case .notebookName: return "Notebook name"
        case .pageNumber:   return "Page number"
        case .pageDate:     return "Page date"
        case .todaysDate:   return "Today's date"
        case .custom:       return "Custom text"
        }
    }
}

/// One key -> value mapping row (e.g. a Notion column -> a note field).
struct FieldMapping: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: NoteFieldValue

    init(id: UUID = UUID(), key: String, value: NoteFieldValue) {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// Reusable +/- list of key -> value mappings. Keys are chosen from
/// `availableKeys` (e.g. a database's columns); each value is a note field or
/// custom text. Designed to be dropped into any destination that maps fields.
struct FieldMappingControl: View {
    @Binding var rows: [FieldMapping]
    let availableKeys: [String]
    var keyLabel: String = "Column"

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("No mappings yet. Add one to fill a \(keyLabel.lowercased()).")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            } else {
                ForEach($rows) { $row in
                    mappingRow($row)
                }
            }
            addButton
                .disabled(availableKeys.isEmpty)
                .padding(.top, 6)
        }
    }

    private func mappingRow(_ row: Binding<FieldMapping>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: row.key) {
                ForEach(availableKeys, id: \.self) { key in
                    Text(key).tag(key)
                }
            }
            .labelsHidden()
            .fixedSize()

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiary)

            Picker("", selection: Binding(
                get: { row.wrappedValue.value.kind },
                set: { row.wrappedValue.value = .make(kind: $0, custom: row.wrappedValue.value.customText) }
            )) {
                ForEach(NoteFieldKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()

            if row.wrappedValue.value.kind == .custom {
                TextField("Custom text", text: Binding(
                    get: { row.wrappedValue.value.customText },
                    set: { row.wrappedValue.value = .custom($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            }

            Spacer(minLength: 0)

            Button(action: { remove(row.wrappedValue.id) }) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.destructive)
            }
            .buttonStyle(.plain)
            .help("Remove mapping")
        }
    }

    private var addButton: some View {
        Button(action: addRow) {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                Text("Add mapping")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.primary)
        }
        .buttonStyle(.plain)
    }

    private func addRow() {
        let used = Set(rows.map(\.key))
        let nextKey = availableKeys.first(where: { !used.contains($0) }) ?? availableKeys.first ?? ""
        rows.append(FieldMapping(key: nextKey, value: .noteTitle))
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }
}
