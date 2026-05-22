//
//  NotebookScopePicker.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Lets a rule sync a whole folder or hand-pick notebooks (e.g. "only my
/// journal"). "Sync every notebook" maps to a nil scope; checking notebooks
/// reports the chosen `RmFile` ids back through `onChange`.
struct NotebookScopePicker: View {
    let files: [RmFile]
    let isLoading: Bool
    /// The rule's current scope: nil/empty means the whole folder.
    let selectedFileIds: [String]?
    /// Persists a new scope (nil for whole folder, or the chosen document ids).
    let onChange: ([String]?) -> Void

    @Environment(\.theme) private var theme

    private var syncsEntireFolder: Bool { (selectedFileIds ?? []).isEmpty }

    var body: some View {
        AppCard("Notebooks") {
            VStack(spacing: 0) {
                AppSettingRow("Sync every notebook", description: syncsEntireFolder
                              ? "Every notebook in this folder syncs, including new ones."
                              : "Only the notebooks you check below sync.") {
                    Toggle("", isOn: Binding(
                        get: { syncsEntireFolder },
                        // Hand-picking needs the loaded document list; with none,
                        // stay on whole-folder rather than writing an empty scope.
                        set: { all in onChange((all || files.isEmpty) ? nil : files.map(\.id)) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                    .disabled(isLoading)
                }
                if !syncsEntireFolder {
                    AppRowDivider().padding(.vertical, 10)
                    checklist
                }
            }
        }
    }

    @ViewBuilder
    private var checklist: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading notebooks…").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if files.isEmpty {
            Text("No notebooks in this folder.")
                .font(.system(size: 11)).foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let selected = Set(selectedFileIds ?? files.map(\.id))
            VStack(spacing: 4) {
                ForEach(files) { file in
                    let isOn = selected.contains(file.id)
                    Button(action: { toggle(file, on: !isOn) }) {
                        HStack(spacing: 10) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(isOn ? theme.primary : theme.tertiary)
                            Text(file.name).font(.system(size: 12)).foregroundStyle(theme.foreground).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(file.pageCount) page\(file.pageCount == 1 ? "" : "s")")
                                .font(.system(size: 10)).foregroundStyle(theme.muted)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ file: RmFile, on: Bool) {
        var ids = Set(selectedFileIds ?? files.map(\.id))
        if on { ids.insert(file.id) } else { ids.remove(file.id) }
        // Report in folder order so the stored list is stable and readable.
        onChange(files.map(\.id).filter { ids.contains($0) })
    }
}
