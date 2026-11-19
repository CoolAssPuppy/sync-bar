//
//  ActivityView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The sync history, now a first-class tab rather than a drawer. Wraps the
//  existing SyncLogView.
//

import SwiftUI
import AppKit

struct ActivityView: View {
    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @Binding var search: String
    @Binding var selectedEventType: String
    @State private var isConfirmingClear = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.divider).frame(height: 1)
            ScrollView { SyncLogView(search: $search, selectedEventType: $selectedEventType) }
            Rectangle().fill(theme.divider).frame(height: 1)
            footer
        }
        .background(theme.background)
        .confirmationDialog("Delete the activity log?", isPresented: $isConfirmingClear) {
            Button("Delete", role: .destructive) { ledger.clearEvents() }
        }
        .alert("Couldn't export the log", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.foreground)
                Text("\(ledger.events.count) event\(ledger.events.count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 16)
            searchField
            filterPicker
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(theme.muted)
            TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 180)
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.borderStrong, lineWidth: 1))
    }

    private var filterPicker: some View {
        Picker("", selection: $selectedEventType) {
            Text("All events").tag("all")
            Text("Synced").tag(SyncEventType.pageSynced.rawValue)
            Text("Failed").tag(SyncEventType.pageFailed.rawValue)
            Text("Runs").tag(SyncEventType.ruleRunCompleted.rawValue)
            Text("Skipped").tag(SyncEventType.cycleSkipped.rawValue)
        }
        .labelsHidden().controlSize(.large).fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            AppSecondaryButton(title: "Export…", systemImage: "square.and.arrow.up") { exportLog() }
            AppSecondaryButton(title: "Delete log", systemImage: "trash", tint: .destructive) { isConfirmingClear = true }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func exportLog() {
        guard let data = ledger.exportSnapshot() else {
            exportError = "Sync Bar couldn't read its log."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "syncbar-activity.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                exportError = Formatters.userMessage(for: error)
            }
        }
    }
}
