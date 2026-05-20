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
    var propertyMappings: [String: NotionPropertyMapping] = [:]
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
