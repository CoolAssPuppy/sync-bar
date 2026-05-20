//
//  NotionForm.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Async load state for a Notion fetch (destinations list, database schema).
enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)
}

struct NotionForm: View {
    @Binding var binding: NotionFormState
    let workspaces: [NotionWorkspace]
    @State private var destinations: LoadState<[NotionDestination]> = .idle
    @State private var schema: LoadState<[NotionDatabaseProperty]> = .idle
    @Environment(\.theme) private var theme

    private var notion: NotionClient {
        NotionClientFactory.make(workspaceId: binding.workspaceId.isEmpty ? nil : binding.workspaceId)
    }

    var body: some View {
        VStack(spacing: 14) {
            AppCard("Notion") {
                VStack(spacing: 0) {
                    AppSettingRow("Workspace", description: nil) {
                        Picker("", selection: $binding.workspaceId) {
                            Text("Select…").tag("")
                            ForEach(workspaces) { workspace in
                                Text(workspace.workspaceName).tag(workspace.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: binding.workspaceId) { _, newValue in
                            Task { await loadDestinations(workspaceId: newValue) }
                        }
                    }
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Page or database", description: destinationsHint) {
                        Picker("", selection: $binding.destinationId) {
                            Text("Select…").tag("")
                            ForEach(destinationsList) { destination in
                                Text("\(destination.icon ?? "•") \(destination.title)").tag(destination.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!isDestinationsReady)
                        .onChange(of: binding.destinationId) { _, newValue in
                            if let dest = destinationsList.first(where: { $0.id == newValue }) {
                                binding.destinationType = dest.type
                                binding.destinationTitle = dest.title
                                if dest.type == .database {
                                    Task { await loadSchema(destinationId: newValue) }
                                } else {
                                    schema = .idle
                                }
                            }
                        }
                    }
                }
            }
            if binding.destinationType == .database {
                AppCard("Column Mapping") {
                    schemaSection
                }
            }
        }
        .task {
            await loadDestinations(workspaceId: binding.workspaceId)
            if binding.destinationType == .database {
                await loadSchema(destinationId: binding.destinationId)
            }
        }
    }

    private var destinationsList: [NotionDestination] {
        if case .loaded(let list) = destinations { return list }
        return []
    }

    private var isDestinationsReady: Bool {
        if case .loaded = destinations { return true }
        return false
    }

    private var destinationsHint: LocalizedStringKey? {
        switch destinations {
        case .idle:    return nil
        case .loading: return "Loading from Notion…"
        case .loaded:  return nil
        case .failed(let message): return LocalizedStringKey(message)
        }
    }

    /// Database columns the user can map (the title column is set automatically
    /// from the rule's title strategy, so it's excluded here).
    private func mappableColumns(_ properties: [NotionDatabaseProperty]) -> [String] {
        properties.filter { $0.type != "title" }.map(\.name)
    }

    @ViewBuilder
    private var schemaSection: some View {
        switch schema {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading database schema…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.destructive)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.destructive)
            }
        case .loaded(let properties):
            VStack(alignment: .leading, spacing: 10) {
                Text("Fill database columns with fields from each note.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                FieldMappingControl(rows: $binding.mappingRows, availableKeys: mappableColumns(properties))
            }
        }
    }

    private func loadDestinations(workspaceId: String) async {
        guard !workspaceId.isEmpty else { destinations = .idle; return }
        destinations = .loading
        do {
            let list = try await notion.listDestinations(workspaceId: workspaceId)
            destinations = .loaded(list)
        } catch {
            destinations = .failed(Formatters.userMessage(for: error))
        }
    }

    private func loadSchema(destinationId: String) async {
        guard !destinationId.isEmpty else { schema = .idle; return }
        schema = .loading
        do {
            let properties = try await notion.databaseSchema(destinationId: destinationId, workspaceId: binding.workspaceId)
            schema = .loaded(properties)
        } catch {
            schema = .failed(Formatters.userMessage(for: error))
        }
    }
}
