//
//  RequiredTagsControl.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Loads the reMarkable tag list and lets the user choose which tags a note must
/// carry to sync to a destination. Bound to a `[String]` (empty = sync every
/// note). Shared by every destination's editor, so "only sync tagged notes" is
/// consistent across destinations rather than Linear-only.
struct RequiredTagsControl: View {
    @Binding var requiredTags: [String]

    @State private var tags: LoadState<[String]> = .idle
    @Environment(\.theme) private var theme

    var body: some View {
        // Without a paired reMarkable the client factory returns the mock, whose
        // sample tags would mislead the user into filtering on tags that don't
        // exist on their device. Only offer tags once there's a real source.
        if Ledger.shared.remarkableAccount == nil {
            Text("Pair your reMarkable to filter by tag")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiary)
        } else {
            content.task { await loadTags() }
        }
    }

    @ViewBuilder
    private var content: some View {
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
            Button(action: { requiredTags = [] }) {
                Label("Any tag (sync all notes)", systemImage: requiredTags.isEmpty ? "checkmark" : "")
            }
            Divider()
            ForEach(available, id: \.self) { tag in
                Button(action: { toggle(tag) }) {
                    Label(tag, systemImage: requiredTags.contains(tag) ? "checkmark" : "")
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
        if requiredTags.isEmpty { return "Any tag" }
        if requiredTags.count == 1 { return requiredTags[0] }
        return "\(requiredTags.count) tags"
    }

    private func toggle(_ tag: String) {
        if let index = requiredTags.firstIndex(of: tag) {
            requiredTags.remove(at: index)
        } else {
            requiredTags.append(tag)
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
