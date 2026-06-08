//
//  MarkdownForm.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct MarkdownForm: View {
    @Binding var binding: MarkdownFormState
    /// Unused now that Markdown is one generic connection (folder is chosen per
    /// sync below). Kept so the older binding editor compiles unchanged.
    let targets: [MarkdownTarget]

    var body: some View {
        AppCard("Markdown Files") {
            VStack(spacing: 0) {
                AppSettingRow("Destination folder", description: "Where the .md files land for this sync.") {
                    HStack(spacing: 6) {
                        Text(binding.folderPath.isEmpty ? "Not chosen" : binding.folderPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                        AppSecondaryButton(title: "Choose…", systemImage: "folder") {
                            chooseFolder()
                        }
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("File name template", description: "Use / for subfolders. Tokens: {folder_name}, {notebook}, {page_n}, {date}, {title}") {
                    TextField(MarkdownTarget.defaultFileNameTemplate, text: $binding.fileNameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Frontmatter", description: "All columns, the essential fields, or none.") {
                    Picker("", selection: $binding.frontmatterMode) {
                        ForEach(FrontmatterMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private func chooseFolder() {
        if let path = FolderChooser.choose() { binding.folderPath = path }
    }
}
