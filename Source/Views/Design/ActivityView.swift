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

    @State private var search = ""
    @State private var selectedEventType = "all"

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.divider).frame(height: 1)
            ScrollView { SyncLogView(search: $search, selectedEventType: $selectedEventType) }
            Rectangle().fill(theme.divider).frame(height: 1)
            footer
        }
        .background(theme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.foreground)
                Text("\(ledger.events.count) event\(ledger.events.count == 1 ? "" : "s") recorded")
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
            Text("Page synced").tag(SyncEventType.pageSynced.rawValue)
            Text("Page failed").tag(SyncEventType.pageFailed.rawValue)
            Text("Run completed").tag(SyncEventType.ruleRunCompleted.rawValue)
            Text("Orphans").tag(SyncEventType.orphanDetected.rawValue)
        }
        .labelsHidden().controlSize(.large).fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            AppSecondaryButton(title: "Export ledger…", systemImage: "square.and.arrow.up") { exportLedger() }
            AppSecondaryButton(title: "Clear log", systemImage: "trash", tint: .destructive) { ledger.clearEvents() }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func exportLedger() {
        guard let data = ledger.exportSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "syncbar-ledger.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
