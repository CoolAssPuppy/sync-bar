//
//  SyncLogDrawer.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

/// Same chrome as `SettingsDrawer` but slides the sync log down from the top.
/// Hosts the existing `SyncLogView`, plus footer actions for Export ledger
/// and Clear log so the user doesn't have to hunt those in Settings.
struct SyncLogDrawer: View {
    @Binding var isPresented: Bool
    var contentHeight: CGFloat = 600

    @Environment(\.theme) private var theme
    @ObservedObject private var ledger = Ledger.shared

    var body: some View {
        ZStack(alignment: .top) {
            if isPresented {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)

                drawer
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .background(EscapeKeyMonitor(isActive: isPresented, onEscape: close))
            }
        }
        .animation(.easeOut(duration: 0.26), value: isPresented)
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.divider).frame(height: 1)
            ScrollView { SyncLogView() }
                .frame(maxHeight: contentHeight)
            Rectangle().fill(theme.divider).frame(height: 1)
            footer
        }
        .background(theme.surface)
        .overlay(drawerShape.strokeBorder(theme.border, lineWidth: 1))
        .clipShape(drawerShape)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 14,
                               bottomTrailing: 14, topTrailing: 0),
            style: .continuous
        )
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync log")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("\(ledger.events.count) event\(ledger.events.count == 1 ? "" : "s") recorded · esc to close")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.card))
                    .overlay(Circle().strokeBorder(theme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            AppSecondaryButton(title: "Export ledger…", systemImage: "square.and.arrow.up") {
                exportLedger()
            }
            AppSecondaryButton(title: "Clear log", systemImage: "trash", tint: .destructive) {
                ledger.clearEvents()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(theme.background)
    }

    private func close() { isPresented = false }

    private func exportLedger() {
        guard let data = ledger.exportSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "syncnerds-ledger.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}

// MARK: - Escape key listener (shared with SettingsDrawer)

private struct EscapeKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyMonitorView, context: Context) {
        nsView.onEscape = onEscape
        guard isActive, let window = nsView.window else { return }
        if window.firstResponder !== nsView && !(window.firstResponder is NSTextView) {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder !== nsView &&
                   !(nsView.window?.firstResponder is NSTextView) {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }
}

private final class KeyMonitorView: NSView {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        nextResponder?.keyDown(with: event)
    }
}

// Strip the Clear log + filter chrome from the embedded SyncLogView when
// shown inside the drawer; the drawer's footer hosts those actions instead.
