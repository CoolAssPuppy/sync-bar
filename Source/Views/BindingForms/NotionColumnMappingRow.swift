//
//  NotionColumnMappingRow.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Renders the right kind of editor for each Notion property type, including
/// a multi-select chip box for `multi_select` columns.
struct NotionColumnMappingRow: View {
    let property: NotionDatabaseProperty
    @Binding var mapping: NotionPropertyMapping
    @Environment(\.theme) private var theme

    var body: some View {
        AppSettingRow(LocalizedStringKey(property.name), description: LocalizedStringKey(property.type)) {
            editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch property.type {
        case "title":
            Text("Auto from title strategy")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        case "select", "status":
            singleOptionPicker
        case "multi_select":
            MultiSelectChipBox(options: property.options,
                               selection: Binding(
                                get: { currentMultiSelectValues },
                                set: { mapping = .multiSelectOptions($0) }
                               ))
                .frame(maxWidth: 280, alignment: .trailing)
        case "date":
            datePicker
        case "checkbox":
            checkboxPicker
        case "number":
            numberField
        case "rich_text", "url", "email", "phone_number":
            textField
        default:
            Text("Leave blank")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        }
    }

    private var singleOptionPicker: some View {
        Picker("", selection: Binding<String>(
            get: { currentSelectValue },
            set: { newValue in mapping = newValue.isEmpty ? .leaveBlank : .selectOption(newValue) }
        )) {
            Text("Leave blank").tag("")
            ForEach(property.options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private var datePicker: some View {
        Picker("", selection: Binding<String>(
            get: {
                if case .dateSource(let source) = mapping { return source.rawValue }
                return ""
            },
            set: { raw in
                if raw.isEmpty { mapping = .leaveBlank }
                else if let source = NotionPropertyMapping.DateSource(rawValue: raw) {
                    mapping = .dateSource(source)
                }
            }
        )) {
            Text("Leave blank").tag("")
            ForEach(NotionPropertyMapping.DateSource.allCases) { source in
                Text(source.label).tag(source.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private var checkboxPicker: some View {
        Picker("", selection: Binding<Int>(
            get: {
                if case .checkbox(let value) = mapping { return value ? 1 : 0 }
                return -1
            },
            set: { tag in
                if tag == -1 { mapping = .leaveBlank }
                else { mapping = .checkbox(tag == 1) }
            }
        )) {
            Text("Leave blank").tag(-1)
            Text("Unchecked").tag(0)
            Text("Checked").tag(1)
        }
        .labelsHidden()
        .frame(width: 160)
    }

    private var numberField: some View {
        TextField("Number", text: Binding<String>(
            get: {
                if case .number(let value) = mapping { return String(value) }
                return ""
            },
            set: { raw in
                if raw.isEmpty { mapping = .leaveBlank }
                else if let value = Double(raw) { mapping = .number(value) }
            }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: 160)
    }

    private var textField: some View {
        TextField("Leave blank or use a template", text: Binding<String>(
            get: {
                switch mapping {
                case .text(let template): return template
                case .literal(let value): return value
                default: return ""
                }
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { mapping = .leaveBlank }
                else if property.type == "rich_text" { mapping = .text(template: trimmed) }
                else { mapping = .literal(trimmed) }
            }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 280)
    }

    private var currentSelectValue: String {
        if case .selectOption(let value) = mapping { return value }
        return ""
    }

    private var currentMultiSelectValues: [String] {
        if case .multiSelectOptions(let values) = mapping { return values }
        return []
    }
}

/// Chip-box editor for multi-select columns. + button pops a menu of the
/// remaining Notion options; each existing chip has a × to remove it.
struct MultiSelectChipBox: View {
    let options: [String]
    @Binding var selection: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let remaining = options.filter { !selection.contains($0) }
        HStack(alignment: .center, spacing: 6) {
            ForEach(selection, id: \.self) { value in
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.primary)
                    Button(action: { selection.removeAll { $0 == value } }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.primary.opacity(0.12)))
                .overlay(Capsule().strokeBorder(theme.primary.opacity(0.3), lineWidth: 1))
            }
            if !remaining.isEmpty {
                Menu {
                    ForEach(remaining, id: \.self) { option in
                        Button(option) { selection.append(option) }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 18, height: 18)
                        .background(Capsule().fill(theme.primary.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(theme.primary.opacity(0.3), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(6)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
