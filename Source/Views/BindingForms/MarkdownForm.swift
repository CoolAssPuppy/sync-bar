//
//  MarkdownForm.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

struct MarkdownForm: View {
    @Binding var binding: MarkdownFormState
    let targets: [MarkdownTarget]

    var body: some View {
        AppCard("Markdown files") {
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
                if !targets.isEmpty {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Pick an existing target", description: nil) {
                        Picker("", selection: $binding.folderPath) {
                            ForEach(targets) { target in
                                Text(target.displayName).tag(target.folderPath)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("File name template", description: "Tokens: {notebook}, {page_n}, {date}, {title}") {
                    TextField("{notebook}-page-{page_n}", text: $binding.fileNameTemplate)
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Pick a folder for Markdown notes"
        if panel.runModal() == .OK, let url = panel.url {
            binding.folderPath = url.path
        }
    }
}
