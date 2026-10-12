import AppKit

/// Command shortcuts Pickup handles itself. An accessory (LSUIElement) app has no usable main menu,
/// and a transient popover may close on activation changes before key equivalents are resolved, so
/// these are matched in a local event monitor (`StatusItemController`), only for Pickup's own windows.
enum AppShortcut: Equatable {
    case openSettings   // ⌘,
    case quit           // ⌘Q
    case closeWindow    // ⌘W

    /// `characters` must be `charactersIgnoringModifiers` (layout-independent for the letter keys).
    /// Only ⌘ alone counts; ⌘⇧, ⌘⌥ and friends are left to the responder chain.
    static func match(characters: String?, modifiers: NSEvent.ModifierFlags) -> AppShortcut? {
        let relevant = modifiers.intersection([.command, .shift, .option, .control])
        guard relevant == .command, let key = characters?.lowercased() else { return nil }
        switch key {
        case ",": return .openSettings
        case "q": return .quit
        case "w": return .closeWindow
        default: return nil
        }
    }
}
