//
//  AppleNotesForm.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct AppleNotesForm: View {
    @Binding var binding: AppleNotesFormState

    /// Sentinel selection meaning "create a new folder" (typed below).
    private static let createNewTag = "\u{0}__create_new__"

    @State private var folders: LoadState<[String]> = .idle
    @State private var selection: String = createNewTag
    @Environment(\.theme) private var theme

    private var isCreatingNew: Bool { selection == Self.createNewTag }

    var body: some View {
        AppCard("Apple Notes") {
            VStack(spacing: 0) {
                AppSettingRow("Folder", description: "Pick an existing iCloud Notes folder, or create a new one.") {
                    folderControl
                }
                if isCreatingNew {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("New folder name", description: nil) {
                        TextField("Sync Bar", text: $binding.folderName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 260)
                    }
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
                Text("Loading folders…").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
        case .failed:
            // Couldn't read Notes (e.g. automation permission not granted yet).
            // Fall back to typing the folder name so setup still works.
            TextField("Folder name", text: $binding.folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        case .loaded(let list):
            Picker("", selection: $selection) {
                Text("Create new…").tag(Self.createNewTag)
                if !list.isEmpty {
                    Divider()
                    ForEach(list, id: \.self) { Text($0).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: selection) { _, newValue in
                if newValue != Self.createNewTag { binding.folderName = newValue }
            }
        }
    }

    private func loadFolders() async {
        guard case .idle = folders else { return }
        folders = .loading
        do {
            let list = try await AppleNotesDestinationClient.listFolders()
            folders = .loaded(list)
            // Select the current folder if it exists; otherwise default to
            // "create new" seeded with whatever the binding already held.
            selection = list.contains(binding.folderName) ? binding.folderName : Self.createNewTag
        } catch {
            folders = .failed(Formatters.userMessage(for: error))
        }
    }
}
