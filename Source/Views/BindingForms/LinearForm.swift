//
//  LinearForm.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct LinearForm: View {
    @Binding var binding: LinearFormState
    let accounts: [LinearAccount]

    @State private var tags: LoadState<[String]> = .idle
    @Environment(\.theme) private var theme

    var body: some View {
        AppCard("Linear") {
            VStack(spacing: 0) {
                AppSettingRow("Team", description: nil) {
                    Picker("", selection: $binding.workspaceId) {
                        Text("Select…").tag("")
                        ForEach(accounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Project (optional)", description: nil) {
                    TextField("Project ID or slug", text: $binding.projectId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Default label (optional)", description: nil) {
                    TextField("e.g. captured-from-rm", text: $binding.defaultLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Only sync tagged notes",
                              description: "Limit this destination to reMarkable notes carrying a chosen tag. Leave empty to sync every note.") {
                    tagControl
                }
            }
        }
        .task { await loadTags() }
    }

    @ViewBuilder
    private var tagControl: some View {
        switch tags {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading tags…").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.destructive)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240, alignment: .trailing)
        case .loaded(let available):
            if available.isEmpty {
                Text("No tags found on your reMarkable")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiary)
            } else {
                tagMenu(available: available)
            }
        }
    }

    private func tagMenu(available: [String]) -> some View {
        Menu {
            Button(action: { binding.requiredTags = [] }) {
                Label("Any tag (sync all notes)", systemImage: binding.requiredTags.isEmpty ? "checkmark" : "")
            }
            Divider()
            ForEach(available, id: \.self) { tag in
                Button(action: { toggle(tag) }) {
                    Label(tag, systemImage: binding.requiredTags.contains(tag) ? "checkmark" : "")
                }
            }
        } label: {
            Text(menuLabel)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 240, alignment: .trailing)
    }

    private var menuLabel: String {
        if binding.requiredTags.isEmpty { return "Any tag" }
        if binding.requiredTags.count == 1 { return binding.requiredTags[0] }
        return "\(binding.requiredTags.count) tags"
    }

    private func toggle(_ tag: String) {
        if let index = binding.requiredTags.firstIndex(of: tag) {
            binding.requiredTags.remove(at: index)
        } else {
            binding.requiredTags.append(tag)
        }
    }

    private func loadTags() async {
        guard case .idle = tags else { return }
        tags = .loading
        do {
            tags = .loaded(try await RemarkableClientFactory.make().listTags())
        } catch {
            tags = .failed(Formatters.userMessage(for: error))
        }
    }
}
