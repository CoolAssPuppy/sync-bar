//
//  GoogleDocsForm.swift
//  Sync Bar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct GoogleDocsForm: View {
    @Binding var binding: GoogleFormState
    @Environment(\.theme) private var theme

    var body: some View {
        AppCard("Google Docs") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Drive folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Where new docs are created. Pick a folder, or My Drive for the root.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)

                DriveFolderTree(
                    email: binding.email,
                    selectedId: $binding.folderId,
                    selectedName: $binding.folderName
                )

                AppRowDivider().padding(.vertical, 4)

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
    }
}

// MARK: - Tree

/// Shared, observable state for the folder tree. Lives above the recursive row
/// views so expansion + lazily loaded children survive re-renders.
@MainActor
private final class DriveTreeStore: ObservableObject {
    let email: String
    @Published var rootState: LoadState<[GoogleDriveFolder]> = .idle
    @Published var childrenState: [String: LoadState<[GoogleDriveFolder]>] = [:]
    @Published var expanded: Set<String> = []

    init(email: String) { self.email = email }

    func loadRoot() async {
        guard !email.isEmpty else { rootState = .failed("No Google account on this destination."); return }
        guard case .idle = rootState else { return }
        rootState = .loading
        do {
            rootState = .loaded(try await GoogleTokens.listFolders(email: email, parentId: "root"))
        } catch {
            rootState = .failed(Formatters.userMessage(for: error))
        }
    }

    func toggle(_ folder: GoogleDriveFolder) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        }
        if childrenState[folder.id] == nil {
            Task { await loadChildren(folder.id) }
        }
    }

    private func loadChildren(_ folderId: String) async {
        childrenState[folderId] = .loading
        do {
            childrenState[folderId] = .loaded(try await GoogleTokens.listFolders(email: email, parentId: folderId))
        } catch {
            childrenState[folderId] = .failed(Formatters.userMessage(for: error))
        }
    }
}

/// A lazy, expandable Google Drive folder tree. Top-level folders load on
/// appear; each folder's children load the first time it's expanded. Selecting
/// a row targets that folder; "My Drive" targets the root.
private struct DriveFolderTree: View {
    @Binding var selectedId: String
    @Binding var selectedName: String
    @StateObject private var store: DriveTreeStore
    @Environment(\.theme) private var theme

    init(email: String, selectedId: Binding<String>, selectedName: Binding<String>) {
        _selectedId = selectedId
        _selectedName = selectedName
        _store = StateObject(wrappedValue: DriveTreeStore(email: email))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                myDriveRow
                switch store.rootState {
                case .idle, .loading:
                    DriveStatusRow(depth: 1) { DriveLoadingLabel() }
                case .failed(let message):
                    DriveStatusRow(depth: 1) { DriveErrorLabel(message: message) }
                case .loaded(let folders):
                    if folders.isEmpty {
                        DriveStatusRow(depth: 1) {
                            Text("No folders").font(.system(size: 11)).foregroundStyle(theme.tertiary)
                        }
                    } else {
                        ForEach(folders) { folder in
                            DriveFolderRow(folder: folder, depth: 1, store: store,
                                           selectedId: $selectedId, selectedName: $selectedName)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.cardInset))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .task { await store.loadRoot() }
    }

    private var myDriveRow: some View {
        DriveRowChrome(depth: 0, isSelected: selectedId.isEmpty, onTap: { select(id: "", name: "") }) {
            Color.clear.frame(width: 12)
            Image(systemName: "internaldrive")
                .font(.system(size: 12))
                .foregroundStyle(selectedId.isEmpty ? theme.primary : theme.muted)
                .frame(width: 16)
            Text("My Drive")
                .font(.system(size: 11, weight: selectedId.isEmpty ? .semibold : .regular))
                .foregroundStyle(selectedId.isEmpty ? theme.foreground : theme.foregroundSoft)
            Spacer(minLength: 4)
            if selectedId.isEmpty { DriveSelectedCheck() }
        }
    }

    private func select(id: String, name: String) {
        selectedId = id
        selectedName = name
    }
}

/// One folder row, plus (when expanded) its children. Recursive: it renders
/// `DriveFolderRow` for each child. Named-struct recursion is allowed where a
/// recursive `some View` function would not be.
private struct DriveFolderRow: View {
    let folder: GoogleDriveFolder
    let depth: Int
    @ObservedObject var store: DriveTreeStore
    @Binding var selectedId: String
    @Binding var selectedName: String
    @Environment(\.theme) private var theme

    private var isOpen: Bool { store.expanded.contains(folder.id) }
    private var isSelected: Bool { selectedId == folder.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            DriveRowChrome(depth: depth, isSelected: isSelected,
                           onTap: { selectedId = folder.id; selectedName = folder.name }) {
                Button(action: { store.toggle(folder) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: isOpen ? "folder.fill" : "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(isOpen ? theme.primary : theme.muted)
                    .frame(width: 16)
                    .scaleEffect(isOpen ? 1.06 : 1.0)

                Text(folder.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.foreground : theme.foregroundSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isSelected { DriveSelectedCheck() }
            }

            if isOpen {
                childrenView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var childrenView: some View {
        switch store.childrenState[folder.id] ?? .idle {
        case .idle, .loading:
            DriveStatusRow(depth: depth + 1) { DriveLoadingLabel() }
        case .failed(let message):
            DriveStatusRow(depth: depth + 1) { DriveErrorLabel(message: message) }
        case .loaded(let kids):
            if kids.isEmpty {
                DriveStatusRow(depth: depth + 1) {
                    Text("No subfolders").font(.system(size: 10)).foregroundStyle(theme.tertiary)
                }
            } else {
                ForEach(kids) { child in
                    DriveFolderRow(folder: child, depth: depth + 1, store: store,
                                   selectedId: $selectedId, selectedName: $selectedName)
                }
            }
        }
    }
}

// MARK: - Row chrome

private struct DriveRowChrome<Content: View>: View {
    let depth: Int
    let isSelected: Bool
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) { content() }
            .padding(.leading, CGFloat(depth) * 16 + 4)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.primary.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

private struct DriveStatusRow<Content: View>: View {
    let depth: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
            .padding(.leading, CGFloat(depth) * 16 + 4)
            .padding(.vertical, 3)
    }
}

private struct DriveLoadingLabel: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(.system(size: 11)).foregroundStyle(theme.muted)
        }
    }
}

private struct DriveErrorLabel: View {
    let message: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.destructive)
            .lineLimit(2)
    }
}

private struct DriveSelectedCheck: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.primary)
            .frame(width: 14)
    }
}
