//
//  PickerLoadTracker.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Tracks the editor's network-backed pickers so a failed load says so and
//  offers Retry instead of reading "Loading…" forever.
//

import SwiftUI

enum EditorPicker: Hashable {
    case safariFolders, notionSourceDatabases, notionTaskDatabases, notionDestinations
}

@MainActor
final class PickerLoadTracker: ObservableObject {
    @Published private(set) var loading: Set<EditorPicker> = []
    @Published private(set) var errors: [EditorPicker: String] = [:]

    /// Runs a picker's load, recording loading and failure.
    func run(_ picker: EditorPicker, _ work: @escaping @MainActor () async throws -> Void) {
        loading.insert(picker)
        errors[picker] = nil
        Task { @MainActor in
            do { try await work() } catch { errors[picker] = Formatters.userMessage(for: error) }
            loading.remove(picker)
        }
    }

    func isSettled(_ picker: EditorPicker) -> Bool { !loading.contains(picker) && errors[picker] == nil }

    func placeholder(_ picker: EditorPicker, isEmpty: Bool, ready: String, empty: String) -> String {
        if loading.contains(picker) { return "Loading…" }
        if errors[picker] != nil { return "Couldn't load" }
        return isEmpty ? empty : ready
    }

    @ViewBuilder
    func errorLine(_ picker: EditorPicker, retry: @escaping () -> Void) -> some View {
        if let message = errors[picker] { PickerLoadError(message: message, onRetry: retry) }
    }
}
