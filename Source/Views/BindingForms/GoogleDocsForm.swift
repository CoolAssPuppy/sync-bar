//
//  GoogleDocsForm.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct GoogleDocsForm: View {
    @Binding var binding: GoogleFormState

    @State private var folders: LoadState<[GoogleDriveFolder]> = .idle
    @Environment(\.theme) private var theme

    var body: some View {
        AppCard("Google Docs") {
            VStack(spacing: 0) {
                AppSettingRow("Drive folder", description: "Where new docs are created. Leave on My Drive to use the root.") {
                    folderControl
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Append mode", description: nil) {
                    Picker("", selection: $binding.appendMode) {
                        ForEach(GoogleDocsDestinationConfig.AppendMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .task { await loadFolders() }
    }

    @ViewBuilder
    private var folderControl: some View {
        switch folders {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading folders…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.destructive)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        case .loaded(let list):
            Picker("", selection: $binding.folderId) {
                Text("My Drive (root)").tag("")
                ForEach(list) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: binding.folderId) { _, newValue in
                binding.folderName = list.first(where: { $0.id == newValue })?.name ?? ""
            }
        }
    }

    private func loadFolders() async {
        guard !binding.email.isEmpty else {
            folders = .failed("No Google account on this destination.")
            return
        }
        folders = .loading
        do {
            folders = .loaded(try await GoogleTokens.listFolders(email: binding.email))
        } catch {
            folders = .failed(Formatters.userMessage(for: error))
        }
    }
}
