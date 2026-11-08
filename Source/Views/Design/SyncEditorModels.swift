//
//  SyncEditorModels.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation

enum SyncEditorTarget: Identifiable {
    case new
    case edit(SyncFlow)
    case editTask(TaskSync)
    var id: String {
        switch self {
        case .new:             return "new"
        case .edit(let f):     return f.id
        case .editTask(let s): return "task-" + s.id
        }
    }
}

/// A connected destination account, normalized for the editor's "To" dropdown.
struct ConnectedApp: Identifiable {
    let id: String
    let kind: DestinationKind
    let name: String
    let defaultConfig: DestinationConfiguration
}

extension Ledger {
    var connectedApps: [ConnectedApp] {
        var out: [ConnectedApp] = []
        out += notionWorkspaces.map { ConnectedApp(id: $0.id, kind: .notion, name: $0.workspaceName, defaultConfig: $0.defaultConfiguration) }
        out += linearAccounts.map { ConnectedApp(id: $0.id, kind: .linear, name: $0.name, defaultConfig: $0.defaultConfiguration) }
        out += googleAccounts.map { ConnectedApp(id: $0.id, kind: .googleDocs, name: $0.displayName, defaultConfig: $0.defaultConfiguration) }
        out += markdownTargets.map { ConnectedApp(id: $0.id, kind: .markdownFolder, name: $0.displayName, defaultConfig: .markdownFolder($0.defaultConfiguration)) }
        out += appleNotesTargets.map { ConnectedApp(id: $0.id, kind: .appleNotes, name: "Apple Notes", defaultConfig: $0.defaultConfiguration) }
        out += chromeTargets.map { ConnectedApp(id: $0.id, kind: .chrome, name: $0.displayName, defaultConfig: $0.defaultConfiguration) }
        return out
    }
}
