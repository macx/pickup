import AppKit
import PickupCore
import SwiftUI

@main
struct PickupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item lives in `StatusItemController` (NSStatusItem + NSPopover).
        // Required: an `App` needs a scene. The real Settings window is owned by `StatusItemController`.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `tel:` / `callto:` links arrive as GetURL Apple events.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        let welcome = WelcomePolicy.launchReason()
        // The welcome window asks for the permissions itself; no automatic prompts on top of it.
        model.start(askForPermissions: welcome == nil)
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        if let welcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { statusItem.showWelcome(welcome) }
        }
        retargetSettingsMenuItem()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.retargetSettingsMenuItem() }
        }
        // -PickupOpenSettings / -PickupOpenAbout YES run the menu actions at launch (visual checks).
        if UserDefaults.standard.bool(forKey: "PickupOpenSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { statusItem.openSettings() }
        }
        if UserDefaults.standard.bool(forKey: "PickupOpenAbout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { statusItem.showAbout() }
        }
        // -PickupOpenPopover YES opens the popover at launch (screenshots).
        if UserDefaults.standard.bool(forKey: "PickupOpenPopover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { statusItem.showPopover() }
        }

        // Debug aid: -PickupSelfTestShortcut settings|close|quit posts that ⌘ shortcut to the popover window
        // one second after it opened (synthetic NSEvent through NSApp.postEvent, no accessibility needed).
        if let name = UserDefaults.standard.string(forKey: "PickupSelfTestShortcut") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let key = ["settings": ",", "close": "w", "quit": "q"][name] ?? ","
                guard let window = statusItem.popoverWindow else { return }
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: key,
                                                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) {
                    NSApp.postEvent(event, atStart: true)
                }
            }
        }

        // Debug aid: -PickupSelfTestKey 5 posts a physical key-down for that character to the popover after
        // 3 s and the key-up 1.5 s later (exercises the key monitor and the on-screen highlight).
        if let key = UserDefaults.standard.string(forKey: "PickupSelfTestKey") {
            func post(_ type: NSEvent.EventType) {
                guard let window = statusItem.popoverWindow,
                      let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: key,
                                                   charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
                NSApp.postEvent(event, atStart: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { post(.keyDown) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { post(.keyUp) }
        }

        // Debug aid: -PickupSelfTestCallCycle N [-PickupSelfTestExit YES] stress-tests the call panels (see CallCycleSelfTest).
        if let n = UserDefaults.standard.string(forKey: "PickupSelfTestCallCycle").flatMap(Int.init) {
            let ms = UserDefaults.standard.string(forKey: "PickupSelfTestIntervalMs").flatMap(Int.init) ?? 25
            CallCycleSelfTest.run(cycles: n, interval: .milliseconds(ms))
        }

        // Sleep/wake: drop the link cleanly before sleep, reconnect after wake.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.prepareForSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.systemDidWake() }
        }

        // Debug aid: -PickupSetDefault YES runs the "make default for phone links" flow and logs the outcome.
        if UserDefaults.standard.bool(forKey: "PickupSetDefault") {
            Task { @MainActor in
                await model.linkHandler.makeDefault()
                let line = "isDefault=\(model.linkHandler.isDefault) handler=\(model.linkHandler.handlerName ?? "nil") failure=\(model.linkHandler.failure ?? "nil") detail=\(model.linkHandler.lastErrorDetail ?? "nil")"
                try? line.write(toFile: NSTemporaryDirectory() + "setdefault.txt", atomically: true, encoding: .utf8)
            }
        }

        // Launch argument for visual checks: -PickupDemo incoming|call|remote|popover
        // (`popover` only disables Bluetooth; every -PickupDemo launch also uses invented contacts).
        if let raw = UserDefaults.standard.string(forKey: "PickupDemo") {
            if let demo = AppModel.Demo(rawValue: raw) {
                model.showDemo(demo)
                // -PickupDemoGrow YES: grows the call panel after 2 s to check that it keeps its top-right corner.
                if UserDefaults.standard.bool(forKey: "PickupDemoGrow") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let notice = AudioFallbackReason.audioDropped.localizedNotice
                        model.callUI.active?.notice = notice
                        model.callUI.incoming?.notice = notice
                    }
                }
            }
        }
    }

    /// SwiftUI's own main menu has a "Settings…" (⌘,) item that opens the placeholder `Settings` scene.
    /// Point it at the real Settings window instead.
    @MainActor
    func retargetSettingsMenuItem() {
        guard let menu = NSApp.mainMenu else { return }
        for item in menu.items.compactMap(\.submenu).flatMap(\.items) where item.keyEquivalent == "," {
            item.target = self
            item.action = #selector(openSettingsFromMenu(_:))
        }
    }

    @MainActor @objc private func openSettingsFromMenu(_ sender: Any?) { statusItem?.openSettings() }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        GlobalShortcutManager.shared.shutdown()
        AppModel.shared.shutdown()
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { AppModel.shared.handle(url: $0) }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        Task { @MainActor in AppModel.shared.handle(url: url) }
    }
}
