//
//  BindingFormState.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

// MARK: - Per-kind form state
//
// Editable scratch state for each destination kind. `BindingEditorSheet`
// seeds these from an existing binding's configuration and reads them back
// when saving. One struct per kind keeps the editor's @State declarations flat.

struct NotionFormState {
    var workspaceId: String = ""
    var destinationId: String = ""
    var destinationType: NotionDestinationType = .page
    var destinationTitle: String = ""
    /// Column -> note-field mappings, edited via FieldMappingControl. Converted
    /// to/from the persisted `NotionDestinationConfig.propertyMappings`.
    var mappingRows: [FieldMapping] = []
}

struct LinearFormState {
    var workspaceId: String = ""
    var projectId: String = ""
    var projectName: String = ""
    var defaultLabel: String = ""
}

struct GoogleFormState {
    var email: String = ""
    var folderId: String = ""
    var folderName: String = ""
    var appendMode: GoogleDocsDestinationConfig.AppendMode = .onePerPage
}

struct AppleNotesFormState {
    var folderName: String = "Sync Bar"
}

struct MarkdownFormState {
    var folderPath: String = ""
    var fileNameTemplate: String = "{notebook}-page-{page_n}"
    var includeFrontmatter: Bool = true
}

extension NotionFormState {
    /// Builds editable mapping rows from the persisted property mappings.
    /// Token-based (`.text`) and option-based (`.selectOption` /
    /// `.multiSelectOptions`) mappings round-trip through the control.
    static func mappingRows(from propertyMappings: [String: NotionPropertyMapping]) -> [FieldMapping] {
        propertyMappings
            .compactMap { key, mapping -> FieldMapping? in
                switch mapping {
                case .text(let template):
                    return FieldMapping(key: key, value: NoteFieldValue(token: template))
                case .multiSelectOptions(let names):
                    return FieldMapping(key: key, value: .options(names))
                case .selectOption(let name):
                    return FieldMapping(key: key, value: .options([name]))
                default:
                    return nil
                }
            }
            .sorted { $0.key < $1.key }
    }

    /// Converts mapping rows back into the persisted property-mapping shape.
    /// Selected options become `.multiSelectOptions`; the write path narrows it
    /// to the column's actual type (select / status take the first option).
    static func propertyMappings(from rows: [FieldMapping]) -> [String: NotionPropertyMapping] {
        var output: [String: NotionPropertyMapping] = [:]
        for row in rows where !row.key.isEmpty {
            if case .options(let names) = row.value {
                output[row.key] = names.isEmpty ? .leaveBlank : .multiSelectOptions(names)
            } else {
                output[row.key] = .text(template: row.value.token)
            }
        }
        return output
    }
}
