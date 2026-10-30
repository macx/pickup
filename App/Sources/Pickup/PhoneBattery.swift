import Foundation

/// Where Pickup shows the phone's battery charge (Settings).
enum BatteryDisplay: String, CaseIterable, Identifiable {
    /// Battery gauge and percentage in the popover's status line ("Connected to …").
    case popover
    /// Percentage next to the menu bar icon.
    case menuBar
    case off

    static let defaultsKey = "phoneBatteryDisplay"
    var id: String { rawValue }
}

/// The phone's battery as HFP reports it: a level from 0 to 5 (`battchg`), so the percentage moves
/// in steps of 20.
enum PhoneBattery {
    static func percent(level: Int) -> Int { min(max(level, 0), 5) * 20 }

    /// Filled share of the gauge, 0...1.
    static func fraction(level: Int) -> Double { Double(percent(level: level)) / 100 }

    /// "60 %" (German) or "60%" (English), in the user's locale. The space some locales put before
    /// the percent sign is a narrow one (half the width), which reads better at small sizes.
    static func percentText(level: Int, locale: Locale = .current) -> String {
        (Double(percent(level: level)) / 100).formatted(.percent.locale(locale))
            .replacingOccurrences(of: "\u{00A0}", with: "\u{202F}")
    }
}
