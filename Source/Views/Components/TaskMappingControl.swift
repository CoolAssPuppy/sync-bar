//
//  TaskMappingControl.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The +/- mapping table for a two-way Reminders <-> Notion sync, mirroring the
//  reMarkable column-mapping control. Each row pairs a Reminders field with a
//  Notion column; you add as many as you want. The title is mapped automatically
//  (to the database's title column) and isn't a row. The editor folds these rows
//  into a TaskFieldMapping on save and expands one back into rows on load.
//

import SwiftUI

/// A Reminders field that can be mapped to a Notion column. Title is excluded —
/// it always maps to the database's title column.
enum ReminderField: String, CaseIterable, Identifiable, Hashable {
    case list, due, status, notes, priority

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list:     return "List"
        case .due:      return "Due date"
        case .status:   return "Status"
        case .notes:    return "Notes"
        case .priority: return "Priority"
        }
    }

    /// Notion column types this field can map to.
    var columnTypes: [String] {
        switch self {
        case .list:     return ["select", "status", "multi_select", "rich_text"]
        case .due:      return ["date"]
        case .status:   return ["status", "select", "checkbox"]
        case .notes:    return ["rich_text"]
        case .priority: return ["select", "status"]
        }
    }
}

/// One Reminders field → Notion column pairing.
struct TaskMapRow: Identifiable, Equatable, Hashable {
    let id: UUID
    var field: ReminderField
    var column: String

    init(id: UUID = UUID(), field: ReminderField, column: String) {
        self.id = id
        self.field = field
        self.column = column
    }
}

/// +/- list of Reminders field → Notion column rows. Each field appears at most
/// once; the column picker is filtered to the field's compatible types.
struct TaskMappingControl: View {
    @Binding var rows: [TaskMapRow]
    let schema: [NotionDatabaseProperty]

    @Environment(\.theme) private var theme

    private func columns(for field: ReminderField) -> [String] {
        schema.filter { field.columnTypes.contains($0.type) }.map(\.name)
    }

    /// Fields not yet mapped (so each is offered once).
    private func availableFields(excluding current: ReminderField?) -> [ReminderField] {
        let used = Set(rows.map(\.field)).subtracting(current.map { [$0] } ?? [])
        return ReminderField.allCases.filter { !used.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $row in
                mappingRow($row)
            }
            addButton
                .disabled(availableFields(excluding: nil).isEmpty)
                .padding(.top, 2)
        }
    }

    private func mappingRow(_ row: Binding<TaskMapRow>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { row.wrappedValue.field },
                set: { newField in
                    row.wrappedValue.field = newField
                    // Keep the column only if it still fits the new field's types.
                    if !columns(for: newField).contains(row.wrappedValue.column) {
                        row.wrappedValue.column = columns(for: newField).first ?? ""
                    }
                }
            )) {
                ForEach(availableFields(excluding: row.wrappedValue.field)) { field in
                    Text(field.label).tag(field)
                }
            }
            .labelsHidden()
            .fixedSize()

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiary)

            Picker("", selection: row.column) {
                Text("Choose a column").tag("")
                ForEach(columns(for: row.wrappedValue.field), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .fixedSize()

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
                Image(systemName: "plus.circle.fill").font(.system(size: 13))
                Text("Add mapping").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.primary)
        }
        .buttonStyle(.plain)
    }

    private func addRow() {
        guard let field = availableFields(excluding: nil).first else { return }
        rows.append(TaskMapRow(field: field, column: columns(for: field).first ?? ""))
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }
}
