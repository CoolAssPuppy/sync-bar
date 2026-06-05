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
                AppSettingRow("Include YAML frontmatter", description: nil) {
                    Toggle("", isOn: $binding.includeFrontmatter)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private func chooseFolder() {
        if let path = FolderChooser.choose() { binding.folderPath = path }
    }
}
