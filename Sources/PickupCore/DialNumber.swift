import Foundation

/// A validated dial string that is safe to put into `ATD<number>;`.
///
/// Only an optional leading `+`, digits, `*` and `#` survive. Visual separators (spaces, dashes,
/// dots, slashes, parentheses) are removed. Everything else is rejected, so no input (a `tel:` link
/// from a web page, a pasted string) can inject a second AT command via `;` or CR.
public struct DialNumber: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The normalised dial string, e.g. `+4930123456`.
    public let value: String

    /// Upper bound for a dial string (E.164 allows 15 digits; service codes such as `*#06#` are short).
    public static let maximumLength = 32

    private static let separators: Set<Character> = [" ", "-", ".", "/", "(", ")", "\u{00A0}", "\u{2011}", "\u{2012}", "\u{2013}"]

    public init?(_ raw: String) {
        var result = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if Self.separators.contains(character) { continue }
            if character == "+" {
                // A plus is only allowed as the very first significant character.
                guard result.isEmpty else { return nil }
                result.append(character)
            } else if character.isASCII, character.isNumber || character == "*" || character == "#" {
                result.append(character)
            } else {
                return nil
            }
        }
        let significant = result.filter { $0 != "+" }
        guard !significant.isEmpty, result.count <= Self.maximumLength else { return nil }
        value = result
    }

    /// Parses `tel:` and `callto:` URLs (RFC 3966; `callto://` as used by Skype-style links).
    /// Parameters such as `;phone-context=` are dropped. Returns nil for any other scheme.
    /// Check `isServiceCode` on the result: a web page can put `**21*...%23` into a link.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["tel", "callto", "telprompt"].contains(scheme) else {
            return nil
        }
        // `URL` does not decompose opaque URLs like `tel:+49...`, so work on the string.
        var body = String(url.absoluteString.dropFirst(scheme.count + 1))
        if body.hasPrefix("//") { body.removeFirst(2) }
        if let parameters = body.firstIndex(where: { $0 == ";" || $0 == "?" }) {
            body = String(body[..<parameters])
        }
        guard let decoded = body.removingPercentEncoding else { return nil }
        self.init(decoded)
    }

    /// True if the string contains `*` or `#`: an MMI/USSD code such as `**21*<number>#`
    /// (call forwarding) or `*#06#`, not a plain number. Such codes change phone settings, so they
    /// must not be dialed from a link (`tel:` / `callto:`) without the user's explicit confirmation.
    /// `CallEngine.dial` refuses them unless the caller passes `allowServiceCode: true`
    /// (dial pad, or after a confirmation dialog).
    public var isServiceCode: Bool {
        value.contains("*") || value.contains("#")
    }

    public var description: String { value }
}

/// One DTMF tone for `AT+VTS`.
///
/// Phase 0 finding: the Pixel answers `OK` but the remote party does not hear the tone,
/// so the UI must not rely on DTMF via HFP actually reaching the other side.
public struct DTMFDigit: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let character: Character

    public static let allowed: Set<Character> = Set("0123456789*#ABCD")

    public init?(_ character: Character) {
        let upper = Character(character.uppercased())
        guard Self.allowed.contains(upper) else { return nil }
        self.character = upper
    }

    public var description: String { String(character) }
}
