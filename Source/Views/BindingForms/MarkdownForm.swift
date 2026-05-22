//
//  MarkdownForm.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct MarkdownForm: View {
    @Binding var binding: MarkdownFormState
    let targets: [MarkdownTarget]

    var body: some View {
        AppCard("Markdown Files") {
            VStack(spacing: 0) {
                AppSettingRow("Folder", description: "Where the .md files land.") {
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
                let foldered = targets.filter { !$0.folderPath.isEmpty }
                if !foldered.isEmpty {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Pick an existing target", description: nil) {
                        Picker("", selection: $binding.folderPath) {
                            ForEach(foldered) { target in
                                Text(target.displayName).tag(target.folderPath)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("File name template", description: "Tokens: {notebook}, {page_n}, {date}, {title}") {
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
