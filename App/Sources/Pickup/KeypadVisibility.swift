import Foundation

/// When the keypad is visible: open by the grid button, or automatically while the query looks like
/// a phone number. Pure so it can be tested.
enum KeypadVisibility {
    private static let dialCharacters = Set("0123456789*#+")
    private static let separators = Set(" -().")

    /// Non-empty text made only of dial characters (0-9 + * #) and optional spaces, dashes, dots and
    /// parentheses, with at least one dial character.
    static func isDialQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.contains { dialCharacters.contains($0) }
            && trimmed.allSatisfy { dialCharacters.contains($0) || separators.contains($0) }
    }

    /// - `manuallyOpen`: the user opened the keypad with the grid button (stays until they close it).
    /// - `autoDismissed`: the user closed an automatically opened keypad; honoured until the text stops
    ///   being a dial query (letters or empty field).
    static func resolve(text: String, manuallyOpen: Bool, autoDismissed: Bool) -> Bool {
        manuallyOpen || (isDialQuery(text) && !autoDismissed)
    }
}
