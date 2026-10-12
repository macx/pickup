import Foundation

/// Abbreviates phone numbers before text is written to a persistent log.
///
/// A "phone number" is a run of at least `minimumDigits` digits, optionally starting with `+`
/// and optionally separated by spaces, dashes or parentheses. Only digits may not border the run,
/// so numbers glued to AT commands or URL schemes are caught too (`ATD015112345678;`,
/// `ATD+4917012345678;`, `tel:+4930123456`, `callto:…`, `number=+49…`).
///
/// Tokens that look numeric but are not phone numbers are protected first and never touched:
/// hex values (`0xE00002BC`), Bluetooth addresses (`a4-c3-f0-12-34-56`, `a4:c3:f0:12:34:56`)
/// and absolute file paths. Over-redaction of other digit runs (e.g. a pid) is accepted:
/// a persistent log must rather lose a number than leak one.
///
/// Long numbers keep a short prefix (country / area hint) and the last three digits:
/// `+4955500123` → `+49*****123`. Short ones keep only the last two digits: `12345` → `***45`.
/// Separators are dropped in the redacted form.
public enum PhoneNumberRedaction {
    /// Digit runs shorter than this are left alone (DTMF digits, indicator values, call indices).
    public static let minimumDigits = 5

    private static let phoneRegex = makeRegex(#"\+?(?<![0-9])[0-9](?:[0-9 ()\-]*[0-9])?(?![0-9])"#)

    private static let protectedRegexes = [
        // Hex literals such as IOReturn codes and feature bitmaps.
        makeRegex(#"(?i)0x[0-9a-f]+"#),
        // Bluetooth device addresses, dash or colon separated.
        makeRegex(#"(?i)(?<![0-9a-f])[0-9a-f]{2}(?:[:\-][0-9a-f]{2}){5}(?![0-9a-f])"#),
        // Absolute paths (log file names contain timestamps).
        makeRegex(#"(?<!\S)/\S+"#),
    ]

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // The patterns are compile-time constants; failing here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern) // nosemgrep: pickup-no-force-try
    }

    /// Returns `text` with every phone-number-like run abbreviated.
    public static func redact(_ text: String) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = phoneRegex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        let protected = protectedRegexes.flatMap { $0.matches(in: text, range: fullRange).map(\.range) }

        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                continue
            }
            result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let candidate = nsText.substring(with: range)
            result += abbreviate(candidate) ?? candidate
            cursor = range.location + range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// Abbreviates one candidate, or returns nil if it has too few digits to be a phone number.
    static func abbreviate(_ candidate: String) -> String? {
        let digits = candidate.filter(\.isASCIIDigit)
        guard digits.count >= minimumDigits else { return nil }

        let hasPlus = candidate.hasPrefix("+")
        let keepHead = digits.count >= 9 ? 2 : 0
        let keepTail = digits.count >= 9 ? 3 : 2
        let hidden = digits.count - keepHead - keepTail

        return (hasPlus ? "+" : "")
            + String(digits.prefix(keepHead))
            + String(repeating: "*", count: hidden)
            + String(digits.suffix(keepTail))
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
