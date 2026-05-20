//
//  AppDelegate.swift
//  Sync Bar
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
    private static let spinAnimationKey = "syncbar.spin"

    let coordinator = SyncCoordinator()
    private let launchAtLogin = LaunchAtLoginManager.shared
    private let updater = UpdaterManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Telemetry.setup()
        captureLaunchEvents()

        setupStatusItem()
        subscribeToNotifications()
        coordinator.start()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Log.app.info("Notification authorization denied by the user.")
            }
        }

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

    // MARK: Telemetry

    /// Fires `app.launched` and, when the installed build changed since the
    /// last launch, `update.installed` with the previous/current versions.
    private func captureLaunchEvents() {
        Telemetry.capture("app.launched")

        let versionKey = "\(Bundle.main.bundleIdentifier ?? "syncbar").telemetry.lastVersion"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let previous = UserDefaults.standard.string(forKey: versionKey)
        if let previous, previous != current {
            Telemetry.capture("update.installed", properties: ["from": previous, "to": current])
        }
        if previous != current {
            UserDefaults.standard.set(current, forKey: versionKey)
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        applyStatusItemIcon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        rightClickMenu = buildRightClickMenu()
    }

    private func applyStatusItemIcon(syncing: Bool = false) {
        guard let button = statusItem?.button else { return }
        let assetName = syncing ? "MenuBarIconSyncing" : "MenuBarIcon"
        if let image = NSImage(named: assetName) {
            // Template-rendered name stays muted (system-tinted) while idle;
            // the syncing variant ships its own yellow and opts out of
            // template tinting.
            image.isTemplate = !syncing
            button.image = image
        } else {
            // Fallback if assets are missing for any reason.
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let fallback = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync Bar")?
                .withSymbolConfiguration(config)
            fallback?.isTemplate = true
            button.image = fallback
        }
        button.toolTip = syncing ? "Sync Bar — syncing…" : "Sync Bar"
    }

    private func buildRightClickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Sync now", action: #selector(syncNowMenuAction), keyEquivalent: "")
        menu.addItem(withTitle: "Open Sync Bar", action: #selector(openMainWindowAction), keyEquivalent: "")
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
        menu.addItem(withTitle: "Quit Sync Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
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
        Telemetry.capture("menu.opened")

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
        window.title = "Sync Bar"
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
        applyStatusItemIcon(syncing: true)
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let bounds = layer.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -Double.pi * 2  // clockwise
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: Self.spinAnimationKey)
    }

    private func stopStatusItemSpin() {
        statusItem?.button?.layer?.removeAnimation(forKey: Self.spinAnimationKey)
        applyStatusItemIcon(syncing: false)
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
