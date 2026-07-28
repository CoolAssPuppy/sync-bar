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
    private var cometLayer: CALayer?
    private static let cometAnimationKey = "syncbar.comet"

    let coordinator = SyncCoordinator()
    let taskCoordinator = TaskSyncCoordinator()
    private let entitlement = EntitlementManager.shared
    private let launchAtLogin = LaunchAtLoginManager.shared
    private let updater = UpdaterManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Telemetry.setup()
        captureLaunchEvents()

        setupStatusItem()
        subscribeToNotifications()
        coordinator.start()
        // Validate the paid-source subscription on launch and schedule the daily
        // 00:00 Pacific re-check, so a lapse takes effect even if the app stays open.
        entitlement.start()

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
        Telemetry.capture(.appLaunched)

        let versionKey = "\(Bundle.main.bundleIdentifier ?? "syncbar").telemetry.lastVersion"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let previous = UserDefaults.standard.string(forKey: versionKey)
        if let previous, previous != current {
            Telemetry.capture(.updateInstalled, properties: ["from": previous, "to": current])
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

    private func applyStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        // The template loop stays the button image at all times, so the arrows
        // render in the system-tinted menu-bar color whether idle or syncing.
        // The syncing state is conveyed by the comet overlay (startStatusItemSync),
        // not by swapping the image.
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            button.image = image
        } else {
            // Fallback if assets are missing for any reason.
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let fallback = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync Bar")?
                .withSymbolConfiguration(config)
            fallback?.isTemplate = true
            button.image = fallback
        }
        button.toolTip = "Sync Bar"
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

    @objc private func syncNowMenuAction() { coordinator.syncNow(ruleId: nil); taskCoordinator.syncAll() }
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
        Telemetry.capture(.menuOpened)

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
                // "Sync all" (no specific rule) also reconciles the two-way syncs.
                if ruleId == nil && bindingId == nil { self?.taskCoordinator.syncAll() }
            },
            syncTask: { [weak self] sync in
                Task { await self?.taskCoordinator.run(sync) }
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
            uploadFiles: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showMainWindow()
                // Land on the reMarkable folders view so the user can drag-drop.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    NotificationCenter.default.post(name: .selectRemarkableView, object: nil)
                }
            },
            quit: { NSApp.terminate(nil) }
        )
        let view = MenuBarPopover(coordinator: coordinator, taskCoordinator: taskCoordinator, actions: actions)
        // Make all text (errors especially) selectable/copyable; propagates to
        // descendants and presented sheets.
        popover.contentViewController = NSHostingController(rootView: view.textSelection(.enabled))
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
        window.contentView = NSHostingView(rootView: MainShellView(coordinator: coordinator, taskCoordinator: taskCoordinator).textSelection(.enabled))
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
            .sink { [weak self] _ in self?.startStatusItemSync() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .syncFinished)
            .sink { [weak self] _ in self?.stopStatusItemSync() }
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
        // Hidden maker tool: Settings posts this from the "Twitter" label's
        // context menu; the coordinator lives here, so the run is driven here.
        NotificationCenter.default.publisher(for: .twitterBackfillRequested)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    do {
                        let adopted = try await TwitterBackfill.run(coordinator: self.coordinator)
                        Log.sync.info("Twitter backfill kicked off after adopting \(adopted, privacy: .public) rows")
                    } catch {
                        Log.sync.error("Twitter backfill failed: \(Formatters.userMessage(for: error), privacy: .public)")
                    }
                }
            }
            .store(in: &subscriptions)
    }

    // MARK: Status sync animation

    /// While syncing, the loop arrows hold still and a yellow "comet" of light
    /// orbits clockwise around them — left→right across the top, right→left
    /// across the bottom — so it reads like data flowing through the sync.
    ///
    /// The base template image stays as the button image (so the arrows keep
    /// their system-tinted color). On top we add a glyph-shaped clip whose only
    /// content is a conic yellow wedge that rotates inside the static mask. The
    /// mask is the loop image's own alpha, so the glow lands pixel-perfectly on
    /// the arrows without re-deriving the geometry.
    private func startStatusItemSync() {
        guard let button = statusItem?.button, let image = button.image else { return }
        button.toolTip = "Sync Bar — syncing…"
        button.wantsLayer = true
        guard let hostLayer = button.layer else { return }

        cometLayer?.removeFromSuperlayer()

        let scale = button.window?.backingScaleFactor ?? 2
        let imageSize = image.size
        let originX = ((button.bounds.width - imageSize.width) / 2).rounded()
        let originY = ((button.bounds.height - imageSize.height) / 2).rounded()
        let iconRect = CGRect(x: originX, y: originY, width: imageSize.width, height: imageSize.height)

        let container = CALayer()
        container.frame = iconRect
        container.contentsScale = scale

        // Clip everything inside to the loop shape (the image's alpha). Static —
        // it never rotates, so the arrows stay put.
        var proposed = CGRect(origin: .zero, size: imageSize)
        if let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            let mask = CALayer()
            mask.frame = container.bounds
            mask.contents = cg
            mask.contentsScale = scale
            container.mask = mask
        }

        // A conic gradient: one bright yellow wedge fading to a transparent tail,
        // sized to cover the whole glyph even while rotating.
        let comet = CAGradientLayer()
        comet.type = .conic
        let side = (hypot(iconRect.width, iconRect.height)).rounded(.up)
        comet.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        comet.position = CGPoint(x: iconRect.width / 2, y: iconRect.height / 2)
        comet.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        comet.contentsScale = scale
        comet.startPoint = CGPoint(x: 0.5, y: 0.5)
        comet.endPoint = CGPoint(x: 0.5, y: 0.0)
        // Brighter, more saturated gold with a wider core and a soft trailing fade.
        let yellow = NSColor(red: 1.0, green: 0.78, blue: 0.10, alpha: 1).cgColor
        let clear = NSColor(red: 1.0, green: 0.78, blue: 0.10, alpha: 0).cgColor
        comet.colors = [clear, yellow, yellow, clear, clear]
        comet.locations = [0.0, 0.10, 0.28, 0.62, 1.0]

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2  // clockwise (top L→R, bottom R→L)
        spin.duration = 2.2            // slower, calmer glide
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        comet.add(spin, forKey: Self.cometAnimationKey)

        container.addSublayer(comet)
        hostLayer.addSublayer(container)
        cometLayer = container
    }

    private func stopStatusItemSync() {
        cometLayer?.removeFromSuperlayer()
        cometLayer = nil
        statusItem?.button?.toolTip = "Sync Bar"
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
