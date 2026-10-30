import AppKit
import Observation
import SwiftUI

/// Menu bar item with a popover (arrow attached to the icon, system material, transient).
/// Replaces `MenuBarExtra`, which cannot attach a popover to its icon.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// Red dot on the icon for missed calls the user has not looked at yet.
    private let missedDot = StatusBadgeDot()
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    private var shortcutMonitor: Any?
    /// App that was frontmost before the popover activated Pickup; reactivated on close.
    private var previousApp: NSRunningApplication?
    /// Set when closing the popover to open Settings/About, which must stay in front.
    private var keepActiveOnClose = false

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityIdentifier("status-item")
            button.setAccessibilityLabel(String(localized: "Pickup", comment: "Accessibility label of the menu bar icon. The app name."))
        }
        let content = MenuView(model: model,
                               openSettings: { [weak self] in self?.openSettings() },
                               showAbout: { [weak self] in self?.showAbout() },
                               close: { [weak self] in self?.closePopover() })
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient          // closes on outside click; Esc closes it too
        // Screenshots (-PickupOpenPopover YES): keep it open while other apps take focus.
        if UserDefaults.standard.bool(forKey: "PickupOpenPopover") { popover.behavior = .applicationDefined }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        // While an edge is dragged the popover follows the pointer without its resize animation.
        NotificationCenter.default.addObserver(forName: .pickupPopoverResizing, object: nil, queue: .main) { [weak self] note in
            let resizing = note.object as? Bool ?? false
            MainActor.assumeIsolated {
                self?.popover.animates = !resizing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        trackIcon()
        installShortcutMonitor()
        // Global shortcut (Settings): toggles the popover from anywhere.
        let shortcuts = GlobalShortcutManager.shared
        shortcuts.onTrigger = { [weak self] in self?.togglePopover(nil) }
        shortcuts.start()
        trackShortcutTooltip()
    }

    // MARK: Icon

    /// Re-reads the state whenever it changes: filled handset with call arcs = connected, outlined
    /// handset = disconnected (docs/ICON.md); a red dot for unseen missed calls; the phone's battery
    /// percentage next to the icon when chosen in Settings.
    private func trackIcon() {
        withObservationTracking {
            let connected = model.connection.isConnected || model.isDemo
            let battery = model.batteryDisplay == .menuBar ? model.phoneBattery : nil
            updateIcon(connected: connected, battery: battery, missed: model.hasUnseenMissedCalls)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
    }

    private func updateIcon(connected: Bool, battery: Int?, missed: Bool) {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage(connected: connected)
        if let battery {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            button.title = PhoneBattery.percentText(level: battery)
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
        let name = String(localized: "Pickup", comment: "Accessibility label of the menu bar icon. The app name.")
        var label = missed
            ? String(localized: "\(name), missed calls", comment: "Accessibility label of the menu bar icon while it shows the red dot for missed calls. %@ is the app name.")
            : name
        if let battery {
            label = String(localized: "\(label), phone battery \(PhoneBattery.percentText(level: battery))",
                           comment: "Accessibility label of the menu bar icon with the phone's battery next to it. First %@ is the app name (maybe with \"missed calls\"), second the percentage, e.g. \"60 %\".")
        }
        button.setAccessibilityLabel(label)
        if missedDot.superview !== button { button.addSubview(missedDot) }
        missedDot.isHidden = !missed
        button.layoutSubtreeIfNeeded()
        positionMissedDot()
    }

    /// At the top right of the handset, also when the percentage widens the button.
    private func positionMissedDot() {
        guard let button = statusItem.button else { return }
        let image = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
            ?? NSRect(x: (button.bounds.width - 18) / 2, y: (button.bounds.height - 18) / 2, width: 18, height: 18)
        let size = StatusBadgeDot.diameter
        let y = button.isFlipped ? image.minY - 1 : image.maxY - size + 1
        missedDot.frame = NSRect(x: image.maxX - size + 1, y: y, width: size, height: size)
    }

    /// The template PDFs from App/Resources/MenuBar (copied into the bundle by scripts/build-app.sh). Outside the
    /// app bundle (`swift run`, tests) they are missing, so the SF Symbols stand in.
    private static func menuBarImage(connected: Bool) -> NSImage? {
        let name = connected ? "MenuBarConnected" : "MenuBarDisconnected"
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: connected ? "phone.fill" : "phone", accessibilityDescription: nil)
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true                 // black + alpha; the menu bar tints it for light, dark and selected
        return image
    }

    /// Shows the chosen global shortcut as the menu bar icon's tooltip.
    private func trackShortcutTooltip() {
        withObservationTracking {
            let name = String(localized: "Pickup", comment: "Accessibility label of the menu bar icon. The app name.")
            if let combo = GlobalShortcutManager.shared.combo {
                statusItem.button?.toolTip = String(localized: "\(name) (\(combo.displayString))",
                                                    comment: "Tooltip of the menu bar icon with the global shortcut. First %@ is the app name, second the shortcut, e.g. ⌃⌥P.")
            } else {
                statusItem.button?.toolTip = name
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackShortcutTooltip() }
        }
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        switch StatusItemClick.action(popoverShown: popover.isShown, callIsLive: model.callIsLive,
                                      callPanelVisible: model.panels.isCallPanelVisible) {
        case .closePopover: closePopover()
        case .focusCallPanel: model.panels.focusCallPanel()
        case .showPopover: showPopover()
        }
    }

    /// `retries`: right after launch the status item's button may not be in a window yet (the status bar
    /// attaches it on a later run-loop turn); showing a popover relative to a window-less view does
    /// nothing, so the first click used to be lost. Retry for up to about two seconds.
    func showPopover(retries: Int = 20) {
        guard let button = statusItem.button, !popover.isShown else { return }
        guard button.window != nil else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.showPopover(retries: retries - 1) }
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        keepActiveOnClose = false
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion   // follows the setting live
        NSApp.activate()                        // accessory app: needed for keyboard input in the popover
        NotificationCenter.default.post(name: .pickupPopoverWillShow, object: nil)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NotificationCenter.default.post(name: .pickupPopoverDidShow, object: nil)
        installKeyMonitor()
    }

    /// Arrow keys and Esc go through a local monitor so they work no matter which control has focus
    /// (the text field's field editor can swallow them). Only events for the popover's own window.
    /// ⌘, ⌘Q ⌘W for every Pickup window (popover, Settings, About), independent of the main menu.
    /// Local monitors only see events of this app, so nothing is global: with another app in front
    /// the shortcuts belong to that app.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !ShortcutRecorderState.shared.isRecording, let window = event.window,
                  let shortcut = AppShortcut.match(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
            else { return event }
            switch shortcut {
            case .openSettings: self.openSettings()
            case .quit: NSApp.terminate(nil)
            case .closeWindow:
                if window === self.popover.contentViewController?.view.window { self.closePopover() }
                else if window is NSPanel && window.styleMask.contains(.nonactivatingPanel) { return event } // call panels
                else { window.performClose(nil) }
            }
            return nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.popover.contentViewController?.view.window else { return event }
            let router = DialerKeyRouter.shared
            // ⌘1 / ⌘2 / ⌘3: recent calls tabs.
            if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...3).contains(digit) {
                return (router.selectTab?(digit - 1) ?? false) ? nil : event
            }
            // ⌘C on a selected row copies its number (otherwise the normal copy).
            if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                return (router.copy?() ?? false) ? nil : event
            }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            // Physical dial keys (main row and numpad) light up the on-screen key; typing is untouched.
            let isDialKey = event.characters.map { $0.count == 1 && "0123456789*#".contains($0) } ?? false
            if isDialKey, let key = event.characters {
                router.physicalKey?(key, event.type == .keyDown)
            }
            guard event.type == .keyDown else { return event }
            // Typing while the tabs or the list have focus goes on in the search field.
            if let characters = event.characters, router.typeText?(characters) == true { return nil }
            if isDialKey { return event }
            switch event.keyCode {
            case 126: return (router.move?(-1) ?? false) ? nil : event   // up
            case 125: return (router.move?(1) ?? false) ? nil : event    // down
            case 123: return (router.switchTab?(-1) ?? false) ? nil : event  // left: previous recent calls tab
            case 124: return (router.switchTab?(1) ?? false) ? nil : event   // right: next tab
            case 36, 76:                                                  // return / enter: call the selected row
                return (router.submit?() ?? false) ? nil : event
            case 53:                                                      // esc
                if router.escape?() == true { return nil }
                self.closePopover()
                return nil
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        // Give focus back to the app the user was working in, unless we opened our own window.
        if !keepActiveOnClose { previousApp?.activate() }
        previousApp = nil
    }

    var popoverWindow: NSWindow? { popover.contentViewController?.view.window }

    func closePopover() { popover.performClose(nil) }

    // MARK: Menu actions

    /// Closes the popover first, then shows the Settings window in front. The window is owned here
    /// (not by a SwiftUI `Settings` scene): `showSettingsWindow:` is not reliably delivered in an
    /// accessory (LSUIElement) app without a main menu.
    func openSettings() {
        keepActiveOnClose = true
        closePopover()
        if settingsWindow == nil {
            let window = SettingsWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = String(localized: "Settings", comment: "Title of the Settings window.")
            window.identifier = NSUserInterfaceItemIdentifier("settings-window")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        if let window = settingsWindow as? SettingsWindow, !window.isKeyWindow { window.clearsInitialFocus = true }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func showAbout() {
        keepActiveOnClose = true
        closePopover()
        NSApp.activate()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Pickup",
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .init(rawValue: "Copyright"): String(localized: "Copyright © 2026 David Eiken. All rights reserved.",
                                                 comment: "Copyright line in the About panel."),
        ]
        let credits = NSMutableAttributedString(
            string: String(localized: "Make and answer calls on your Android phone from your Mac.",
                           comment: "One-line description in the About panel."),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        // Links open in the default browser; Pickup itself never goes online.
        let links: [(String?, String?)] = [
            (AppInfo.repositoryURL, String(localized: "Source code on GitHub", comment: "Link text in the About panel.")),
            (AppInfo.websiteURL, nil),   // shown as its domain
        ]
        for case let (string?, text) in links {
            guard let url = URL(string: string), let title = text ?? url.host() else { continue }
            credits.append(NSAttributedString(string: "\n"))
            credits.append(NSAttributedString(
                string: title, attributes: [.link: url, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        }
        options[.credits] = credits
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

/// The missed-call dot: system red, follows light/dark mode and accent changes.
private final class StatusBadgeDot: NSView {
    static let diameter: CGFloat = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)   // the button's label says "missed calls"
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = bounds.width / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the button
}

extension Notification.Name {
    /// Posted once the popover window is key; the dialer focuses the field and puts the caret at the end.
    static let pickupPopoverDidShow = Notification.Name("PickupPopoverDidShow")
    /// Posted right before the popover opens; the dialer resets and focuses its search field.
    static let pickupPopoverWillShow = Notification.Name("PickupPopoverWillShow")
    /// Posted when the user starts (`true`) and stops (`false`) dragging the popover's width.
    static let pickupPopoverResizing = Notification.Name("PickupPopoverResizing")
}

/// Settings window that opens without a focused control. With keyboard navigation turned on, AppKit
/// focuses the first key view (the phone picker) as soon as the window becomes key and draws a focus
/// ring nobody asked for. The first time the window becomes key after each open, the automatic focus is
/// cleared; Tab still moves focus into the controls as usual.
final class SettingsWindow: NSWindow {
    var clearsInitialFocus = true

    override func becomeKey() {
        super.becomeKey()
        guard clearsInitialFocus else { return }
        clearsInitialFocus = false
        DispatchQueue.main.async { [weak self] in _ = self?.makeFirstResponder(nil) }
    }
}
