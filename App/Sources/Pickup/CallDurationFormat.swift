import Foundation

/// Call durations as shown on screen and as read by VoiceOver. Pure, locale-aware.
enum CallDurationFormat {
    /// "0:05", "12:34", "1:02:05" (digits follow the user's locale).
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return Duration.seconds(total).formatted(.time(pattern: total >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// "1 minute, 5 seconds": what VoiceOver reads as the timer's value.
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = total >= 3600 ? [.hours, .minutes, .seconds] : [.minutes, .seconds]
        return Duration.seconds(total).formatted(.units(allowed: allowed, width: .wide))
    }
}
