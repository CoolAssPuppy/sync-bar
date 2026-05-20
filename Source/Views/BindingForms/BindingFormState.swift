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
    /// Only token-based (`.text`) mappings round-trip through the simple control.
    static func mappingRows(from propertyMappings: [String: NotionPropertyMapping]) -> [FieldMapping] {
        propertyMappings
            .compactMap { key, mapping -> FieldMapping? in
                guard case .text(let template) = mapping else { return nil }
                return FieldMapping(key: key, value: NoteFieldValue(token: template))
            }
            .sorted { $0.key < $1.key }
    }

    /// Converts mapping rows back into the persisted property-mapping shape.
    static func propertyMappings(from rows: [FieldMapping]) -> [String: NotionPropertyMapping] {
        var output: [String: NotionPropertyMapping] = [:]
        for row in rows where !row.key.isEmpty {
            output[row.key] = .text(template: row.value.token)
        }
        return output
    }
}
