import AppKit

/// A global shortcut: key plus modifiers. Pure value type (encoding, validation, display, Carbon
/// mapping) so it can be tested without registering anything.
struct KeyCombo: Equatable, Codable, Sendable {
    struct Modifiers: OptionSet, Codable, Sendable {
        let rawValue: UInt
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// Virtual key code (layout independent, what Carbon registers).
    var keyCode: UInt32
    var modifiers: Modifiers
    /// Label recorded with the combo (e.g. "P", "F5", "↩"), so it can be shown without a layout lookup.
    var keyName: String

    /// At least one of ⌘ ⌃ ⌥ is required, so plain letters and ⇧+letter can never be taken over.
    var isValid: Bool { !modifiers.intersection([.command, .option, .control]).isEmpty }

    /// Carbon `RegisterEventHotKey` modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= 0x0100 }
        if modifiers.contains(.shift) { mask |= 0x0200 }
        if modifiers.contains(.option) { mask |= 0x0800 }
        if modifiers.contains(.control) { mask |= 0x1000 }
        return mask
    }

    /// Modifier glyphs in the system order (⌃ ⌥ ⇧ ⌘) followed by the key, e.g. "⌃⌥P".
    var displayString: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + keyName
    }

    // MARK: Recording

    private static let specialKeyNames: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 76: "⌅", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Builds a combo from a key-down event's data; nil for keys without a usable name.
    static func make(keyCode: UInt32, characters: String?, flags: NSEvent.ModifierFlags) -> KeyCombo? {
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let name = specialKeyNames[keyCode] ?? characters?.uppercased().filter { !$0.isWhitespace && !$0.isNewline }
        guard let name, !name.isEmpty else { return nil }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers, keyName: name)
    }

    // MARK: Conflicts

    private struct Known { let keyCode: UInt32; let modifiers: Modifiers }
    /// Shortcuts macOS itself (or nearly every app) uses; registering them may fail or shadow system behaviour.
    private static let knownSystem: [Known] = [
        Known(keyCode: 49, modifiers: [.command]),                    // ⌘␣ Spotlight
        Known(keyCode: 49, modifiers: [.control]),                    // ⌃␣ input source
        Known(keyCode: 49, modifiers: [.command, .option]),           // ⌥⌘␣ Finder search
        Known(keyCode: 49, modifiers: [.control, .command]),          // ⌃⌘␣ emoji
        Known(keyCode: 48, modifiers: [.command]),                    // ⌘⇥ app switcher
        Known(keyCode: 12, modifiers: [.command]),                    // ⌘Q
        Known(keyCode: 12, modifiers: [.control, .command]),          // ⌃⌘Q lock screen
        Known(keyCode: 13, modifiers: [.command]),                    // ⌘W
        Known(keyCode: 4, modifiers: [.command]),                     // ⌘H
        Known(keyCode: 46, modifiers: [.command]),                    // ⌘M
        Known(keyCode: 53, modifiers: [.command, .option]),           // ⌥⌘⎋ force quit
        Known(keyCode: 20, modifiers: [.command, .shift]),            // ⇧⌘3 screenshot
        Known(keyCode: 21, modifiers: [.command, .shift]),            // ⇧⌘4
        Known(keyCode: 23, modifiers: [.command, .shift]),            // ⇧⌘5
        Known(keyCode: 126, modifiers: [.control]),                   // ⌃↑ Mission Control
        Known(keyCode: 125, modifiers: [.control]),                   // ⌃↓ App Exposé
        Known(keyCode: 123, modifiers: [.control]),                   // ⌃← Spaces
        Known(keyCode: 124, modifiers: [.control]),                   // ⌃→ Spaces
    ]

    var isLikelySystemShortcut: Bool {
        Self.knownSystem.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    // MARK: Persistence

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data?) -> KeyCombo? {
        guard let data, let combo = try? JSONDecoder().decode(KeyCombo.self, from: data), combo.isValid else { return nil }
        return combo
    }
}
