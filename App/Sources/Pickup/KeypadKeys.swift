import Foundation

/// Per-key behaviour of the popover keypad. Only "0" has a second function (like the Phone app):
/// a long press inserts "+" and a small "+" is shown below the digit.
enum KeypadKey {
    static let longPressDuration: TimeInterval = 0.4

    /// What a long press inserts instead of the key itself; nil for keys without one.
    static func longPressValue(for key: String) -> String? { key == "0" ? "+" : nil }

    /// Small glyph shown below the key; only keys with a long-press value show one (no letters).
    static func secondaryGlyph(for key: String) -> String? { longPressValue(for: key) }
}
