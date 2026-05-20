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
    case noteName
    case folderName
    case noteDate
    case todaysDate
    case custom(String)
    /// Fixed Notion option(s) chosen for a select / multi_select / status column.
    case options([String])

    var kind: NoteFieldKind {
        switch self {
        case .noteTitle:  return .noteTitle
        case .noteName:   return .noteName
        case .folderName: return .folderName
        case .noteDate:   return .noteDate
        case .todaysDate: return .todaysDate
        case .custom:     return .custom
        case .options:    return .options
        }
    }

    var customText: String {
        if case .custom(let text) = self { return text }
        return ""
    }

    var selectedOptions: [String] {
        if case .options(let names) = self { return names }
        return []
    }

    /// The title-template token (or literal custom text) this value resolves to.
    /// `.options` has no token; it round-trips as a select/multi_select mapping.
    var token: String {
        switch self {
        case .noteTitle:        return "{title}"
        case .noteName:         return "{notebook}"
        case .folderName:       return "{folder_name}"
        case .noteDate:         return "{date}"
        case .todaysDate:       return "{today}"
        case .custom(let text): return text
        case .options:          return ""
        }
    }

    init(token: String) {
        switch token {
        case "{title}":       self = .noteTitle
        case "{notebook}":    self = .noteName
        case "{folder_name}": self = .folderName
        case "{date}":        self = .noteDate
        case "{today}":       self = .todaysDate
        default:              self = .custom(token)
        }
    }

    static func make(kind: NoteFieldKind, custom: String) -> NoteFieldValue {
        switch kind {
        case .noteTitle:  return .noteTitle
        case .noteName:   return .noteName
        case .folderName: return .folderName
        case .noteDate:   return .noteDate
        case .todaysDate: return .todaysDate
        case .custom:     return .custom(custom)
        case .options:    return .options([])
        }
    }
}

enum NoteFieldKind: String, CaseIterable, Identifiable {
    case noteTitle
    case noteName
    case folderName
    case noteDate
    case todaysDate
    case custom
    case options

    var id: String { rawValue }

    /// Kinds offered for plain (non-option) columns.
    static var textKinds: [NoteFieldKind] { allCases.filter { $0 != .options } }

    var label: String {
        switch self {
        case .noteTitle:  return "Title of note"
        case .noteName:   return "Note name"
        case .folderName: return "Folder name"
        case .noteDate:   return "Note date"
        case .todaysDate: return "Today's date"
        case .custom:     return "Custom text"
        case .options:    return "Specific options"
        }
    }
}

/// A destination column the user can map to, plus its selectable options when
/// it's a select / multi_select / status column.
struct MappingColumn: Identifiable, Equatable {
    let name: String
    let options: [String]
    let allowsMultiple: Bool

    var id: String { name }
    var isOptionBased: Bool { !options.isEmpty }
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

/// +/- list of column -> value mappings. Columns come from a Notion database;
/// select / multi_select / status columns let the user pick from the column's
/// own options, everything else maps to a note field or custom text.
struct FieldMappingControl: View {
    @Binding var rows: [FieldMapping]
    let columns: [MappingColumn]
    var keyLabel: String = "Column"

    @Environment(\.theme) private var theme

    private func column(named name: String) -> MappingColumn? {
        columns.first(where: { $0.name == name })
    }

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
                .disabled(columns.isEmpty)
                .padding(.top, 6)
        }
    }

    private func mappingRow(_ row: Binding<FieldMapping>) -> some View {
        let selectedColumn = column(named: row.wrappedValue.key)
        return HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { row.wrappedValue.key },
                set: { newKey in
                    row.wrappedValue.key = newKey
                    // Reset the value to suit the new column's type.
                    let isOption = column(named: newKey)?.isOptionBased == true
                    if isOption, row.wrappedValue.value.kind != .options {
                        row.wrappedValue.value = .options([])
                    } else if !isOption, row.wrappedValue.value.kind == .options {
                        row.wrappedValue.value = .noteName
                    }
                }
            )) {
                ForEach(columns) { column in
                    Text(column.name).tag(column.name)
                }
            }
            .labelsHidden()
            .fixedSize()

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiary)

            if let selectedColumn, selectedColumn.isOptionBased {
                optionsMenu(row: row, column: selectedColumn)
            } else {
                Picker("", selection: Binding(
                    get: { row.wrappedValue.value.kind },
                    set: { row.wrappedValue.value = .make(kind: $0, custom: row.wrappedValue.value.customText) }
                )) {
                    ForEach(NoteFieldKind.textKinds) { kind in
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

    private func optionsMenu(row: Binding<FieldMapping>, column: MappingColumn) -> some View {
        let selected = row.wrappedValue.value.selectedOptions
        return Menu {
            ForEach(column.options, id: \.self) { option in
                Button {
                    toggle(option, in: row, allowsMultiple: column.allowsMultiple)
                } label: {
                    if selected.contains(option) {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            Text(selected.isEmpty
                 ? (column.allowsMultiple ? "Choose options" : "Choose an option")
                 : selected.joined(separator: ", "))
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func toggle(_ option: String, in row: Binding<FieldMapping>, allowsMultiple: Bool) {
        var names = row.wrappedValue.value.selectedOptions
        if allowsMultiple {
            if let index = names.firstIndex(of: option) { names.remove(at: index) } else { names.append(option) }
        } else {
            names = names.contains(option) ? [] : [option]
        }
        row.wrappedValue.value = .options(names)
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
        guard let nextColumn = columns.first(where: { !used.contains($0.name) }) ?? columns.first else { return }
        let value: NoteFieldValue = nextColumn.isOptionBased ? .options([]) : .noteTitle
        rows.append(FieldMapping(key: nextColumn.name, value: value))
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }
}
