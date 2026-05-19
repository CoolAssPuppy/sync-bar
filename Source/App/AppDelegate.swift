//
//  AppDelegate.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var rightClickMenu: NSMenu?
    private var popover: NSPopover?
    private var popoverEventMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var mainWindow: NSWindow?
    private var rotationTask: Task<Void, Never>?
    private var rotationAngle: Double = 0

    let coordinator = SyncCoordinator()
    private let launchAtLogin = LaunchAtLoginManager.shared
    private let updater = UpdaterManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        subscribeToNotifications()
        coordinator.start()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let firstRun = Ledger.shared.notionWorkspaces.isEmpty && Ledger.shared.remarkableAccount == nil
        if AppSettings.shared.openWindowOnLaunch || firstRun {
            // Schedule on the next runloop tick. macOS occasionally rejects
            // window creation during applicationDidFinishLaunching on accessory
            // apps when the screen has just unlocked.
            DispatchQueue.main.async { [weak self] in
                self?.showMainWindow()
            }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        applyStatusItemIcon(syncing: false)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        rightClickMenu = buildRightClickMenu()
    }

    private func applyStatusItemIcon(syncing: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = syncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SyncNerds")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.toolTip = syncing ? "SyncNerds: syncing…" : "SyncNerds"
    }

    private func buildRightClickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Sync now", action: #selector(syncNowMenuAction), keyEquivalent: "")
        menu.addItem(withTitle: "Open SyncNerds", action: #selector(openMainWindowAction), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let pauseItem = NSMenuItem(
            title: AppSettings.shared.pauseSyncing ? "Resume syncing" : "Pause syncing",
            action: #selector(togglePauseAction),
            keyEquivalent: ""
        )
        menu.addItem(pauseItem)
        menu.addItem(withTitle: "Settings", action: #selector(openSettingsDrawerAction), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit SyncNerds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items {
            if item.action != nil {
                item.target = self
            }
        }
        return menu
    }

    @objc private func syncNowMenuAction() { coordinator.syncNow(ruleId: nil) }
    @objc private func openMainWindowAction() { showMainWindow() }
    @objc private func openSettingsDrawerAction() {
        showMainWindow()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            NotificationCenter.default.post(name: .openSettingsDrawer, object: nil)
        }
    }
    @objc private func togglePauseAction() {
        AppSettings.shared.pauseSyncing.toggle()
        rightClickMenu = buildRightClickMenu()
    }
    @objc private func checkForUpdatesAction() { updater.checkForUpdates() }

    @objc func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showRightClickMenu()
        } else {
            togglePopover()
        }
    }

    private func showRightClickMenu() {
        guard let statusItem, let menu = rightClickMenu else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak statusItem] in
            statusItem?.menu = nil
        }
    }

    // MARK: Popover

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = self.popover ?? buildPopover()
        self.popover = popover

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    private func buildPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let actions = MenuBarPopoverActions(
            syncNow: { [weak self] ruleId, bindingId in
                self?.coordinator.syncNow(ruleId: ruleId, bindingId: bindingId)
            },
            openMainWindow: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showMainWindow()
            },
            openSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showMainWindow()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    NotificationCenter.default.post(name: .openSettingsDrawer, object: nil)
                }
            },
            openNotionUrl: { url in
                NSWorkspace.shared.open(url)
            },
            togglePause: {
                AppSettings.shared.pauseSyncing.toggle()
            },
            quit: { NSApp.terminate(nil) }
        )
        let view = MenuBarPopover(coordinator: coordinator, actions: actions)
        popover.contentViewController = NSHostingController(rootView: view)
        return popover
    }

    // MARK: Main window

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existingWindow = mainWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: MainView(coordinator: coordinator))
        window.title = "SyncNerds"
        window.toolbar = nil
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.black
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        mainWindow = window
    }

    // MARK: Notifications

    private func subscribeToNotifications() {
        NotificationCenter.default.publisher(for: .syncStarted)
            .sink { [weak self] _ in self?.startStatusItemSpin() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .syncFinished)
            .sink { [weak self] _ in self?.stopStatusItemSpin() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .pauseSyncingChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rightClickMenu = self.buildRightClickMenu()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .openMainWindow)
            .sink { [weak self] _ in self?.showMainWindow() }
            .store(in: &subscriptions)
    }

    // MARK: Status spin

    private func startStatusItemSpin() {
        rotationTask?.cancel()
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        button.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.rotationAngle += 12
                    self?.applyRotation()
                }
            }
        }
    }

    private func stopStatusItemSpin() {
        rotationTask?.cancel()
        rotationTask = nil
        rotationAngle = 0
        applyRotation()
    }

    private func applyRotation() {
        guard let layer = statusItem?.button?.layer else { return }
        let bounds = layer.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, center.x, center.y, 0)
        transform = CATransform3DRotate(transform, rotationAngle * .pi / 180, 0, 0, 1)
        transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        layer.transform = transform
    }
}

// MARK: - Popover delegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let monitor = popoverEventMonitor {
            NSEvent.removeMonitor(monitor)
            popoverEventMonitor = nil
        }
    }
}

// MARK: - Window delegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == mainWindow else { return }
        mainWindow = nil
    }
}
