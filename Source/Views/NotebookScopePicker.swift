//
//  NotebookScopePicker.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Lets a sync pull a whole folder or hand-pick notebooks (e.g. "only my
/// journal"). "Sync every notebook" maps to a nil scope; checking notebooks
/// reports the chosen `RmFile` ids back through `onChange`. Styled to match the
/// redesigned sync editor (inset cards, gold accents, hover rows).
struct NotebookScopePicker: View {
    let files: [RmFile]
    let isLoading: Bool
    /// The sync's current scope: nil/empty means the whole folder.
    let selectedFileIds: [String]?
    /// Persists a new scope (nil for whole folder, or the chosen document ids).
    let onChange: ([String]?) -> Void

    @Environment(\.theme) private var theme
    @State private var search = ""

    private var syncsEntireFolder: Bool { (selectedFileIds ?? []).isEmpty }
    private var selectedSet: Set<String> { Set(selectedFileIds ?? files.map(\.id)) }

    private var filteredFiles: [RmFile] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            wholeFolderCard
            if !syncsEntireFolder {
                pickCard
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Whole-folder toggle

    private var wholeFolderCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync every notebook")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                Text(syncsEntireFolder
                     ? "Every notebook in this folder syncs, including new ones."
                     : "Only the notebooks you check below sync.")
                    .font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { syncsEntireFolder },
                // Hand-picking needs the loaded document list; with none, stay on
                // whole-folder rather than writing an empty scope.
                set: { all in onChange((all || files.isEmpty) ? nil : files.map(\.id)) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
            .disabled(isLoading || files.isEmpty)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    // MARK: Pick list

    private var pickCard: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.divider).frame(height: 1)
            checklist
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .frame(maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.tertiary)
                TextField("Search notebooks", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(theme.foreground)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .frame(maxWidth: 220)

            Spacer(minLength: 8)

            Button("All") { onChange(nil) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary)
                .disabled(files.isEmpty)
            Text("·").foregroundStyle(theme.border)
            Button("None") { onChange([]) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.muted)
                .disabled(files.isEmpty)

            Text("\(selectedSet.count)/\(files.count)")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.tertiary).monospacedDigit()
                .frame(minWidth: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private var checklist: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading notebooks…").font(.system(size: 12)).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(20)
        } else if files.isEmpty {
            emptyState(icon: "tray", text: "No notebooks in this folder.")
        } else if filteredFiles.isEmpty {
            emptyState(icon: "magnifyingglass", text: "No notebooks match \u{201C}\(search)\u{201D}.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredFiles.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Rectangle().fill(theme.dividerSubtle).frame(height: 1).padding(.leading, 38) }
                        NotebookCheckRow(file: file, isOn: selectedSet.contains(file.id)) { toggle(file, on: $0) }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(theme.muted)
            Text(text).font(.system(size: 12)).foregroundStyle(theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(24)
    }

    private func toggle(_ file: RmFile, on: Bool) {
        var ids = selectedSet
        if on { ids.insert(file.id) } else { ids.remove(file.id) }
        // Report in folder order so the stored list is stable and readable.
        onChange(files.map(\.id).filter { ids.contains($0) })
    }
}

// MARK: - Row

private struct NotebookCheckRow: View {
    let file: RmFile
    let isOn: Bool
    let onToggle: (Bool) -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: { onToggle(!isOn) }) {
            HStack(spacing: 11) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14)).foregroundStyle(isOn ? theme.primary : theme.tertiary)
                    .frame(width: 18)
                Text(file.name)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.foreground)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(file.pageCount) page\(file.pageCount == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(theme.muted).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(isHovered ? theme.cardElevated : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
