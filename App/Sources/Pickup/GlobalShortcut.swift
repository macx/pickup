import AppKit
import Carbon.HIToolbox
import Observation

/// Registers the user's global shortcut with Carbon `RegisterEventHotKey`.
///
/// Why Carbon: it is still the supported way to get a system-wide hot key without any privacy permission
/// (NSEvent global monitors and event taps need Accessibility or Input Monitoring) and it works in a
/// sandboxed app. There is no newer replacement in AppKit/SwiftUI for macOS 26.
@MainActor
@Observable
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()
    static let defaultsKey = "globalShortcut"

    private(set) var combo: KeyCombo?
    /// Called on the main actor when the shortcut is pressed anywhere.
    @ObservationIgnored var onTrigger: (() -> Void)?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?

    private init() {
        combo = TestMode.isActive ? nil : KeyCombo.decode(UserDefaults.standard.data(forKey: Self.defaultsKey))
        // Debug aid for screenshots/tests: -PickupDemoShortcut "6:35:P" (modifier bits : key code : key name).
        if let demo = UserDefaults.standard.string(forKey: "PickupDemoShortcut") {
            let parts = demo.split(separator: ":").map(String.init)
            if parts.count == 3, let mods = UInt(parts[0]), let code = UInt32(parts[1]) {
                combo = KeyCombo(keyCode: code, modifiers: .init(rawValue: mods), keyName: parts[2])
            }
        }
    }

    /// Registers the stored shortcut (call once at launch).
    func start() {
        installHandlerIfNeeded()
        register()
    }

    /// Changes (or clears with nil) the shortcut: persists it and re-registers.
    func set(_ new: KeyCombo?) {
        combo = new
        if let data = new?.encoded() {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        register()
    }

    func shutdown() { unregister() }

    private func register() {
        unregister()
        guard !TestMode.isActive, let combo, combo.isValid else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x504B_5550), id: 1)   // 'PKUP'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcutManager.shared.onTrigger?() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
