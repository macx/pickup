import Foundation

/// Display formatting for phone numbers without third-party code.
///
/// Foundation has no public phone number formatter (Apple's is in a private framework), so this
/// is a deliberate heuristic. Limits:
/// - International numbers (`+<country><national>`) are shown as `+CC AAA NNNNNNN`: the country
///   code comes from a built-in list of the ITU codes, the national part is split after three
///   digits because area/mobile prefix lengths are not known per country. NANP (`+1`) numbers are
///   shown as `+1 (AAA) NNN-NNNN`.
/// - German numbers (`+49`) are grouped only where the prefix length is certain: mobile numbers
///   (`15x`/`16x`/`17x`) as `+49 170 NNNNNNN`, the two-digit big-city area codes (Berlin 30,
///   Hamburg 40, Frankfurt 69, Munich 89) as `+49 30 NNNNNNN`. Every other German landline has an
///   area code of 2 to 5 digits that cannot be known without the full Bundesnetzagentur table, so
///   it is shown as `+49 NNNNNNNNNN`: country code, then the national digits in one block. A
///   wrong split (`+49 230 11234567` for Schwerte, area code 2304) would be misleading; one block
///   is neutral and still readable next to the country code.
/// - National numbers are grouped for German mobile numbers (`015x`/`016x`/`017x`, shown as
///   `0AAA NNNNNNN`) in DE/AT/CH/LI regions and, in the DE region, for the big-city area codes
///   above (`030 NNNNNNN`). All other national numbers are shown exactly as the phone sent them
///   (as are all national numbers in other regions).
/// - Service codes and short numbers (up to 6 digits, or containing `*` / `#`) are shown as is.
/// - Digits are always Western digits; separators do not follow the locale.
enum PhoneNumberFormat {
    private static let oneDigitCodes: Set<String> = ["1", "7"]
    private static let twoDigitCodes: Set<String> = [
        "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
        "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66",
        "81", "82", "84", "86", "90", "91", "92", "93", "94", "95", "98",
    ]
    private static let germanicRegions: Set<String> = ["DE", "AT", "CH", "LI"]
    /// German mobile prefixes (national part without the leading 0).
    private static let germanMobilePrefixes: Set<String> = ["15", "16", "17"]
    /// German two-digit area codes (Berlin, Hamburg, Frankfurt am Main, Munich): the only landline
    /// area codes whose length is certain from the first two digits.
    private static let germanBigCityCodes: Set<String> = ["30", "40", "69", "89"]

    static func display(_ raw: String, region: String? = Locale.current.region?.identifier) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlus = trimmed.hasPrefix("+")
        guard !trimmed.contains(where: { $0 == "*" || $0 == "#" }) else { return trimmed }
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        guard digits.count > 6 else { return trimmed }

        if hasPlus || digits.hasPrefix("00") {
            let international = hasPlus ? digits : String(digits.dropFirst(2))
            return formatInternational(international) ?? trimmed
        }
        if let region, germanicRegions.contains(region), ["015", "016", "017"].contains(String(digits.prefix(3))) {
            let prefix = digits.prefix(4)
            return "\(prefix) \(digits.dropFirst(4))"
        }
        if region == "DE", digits.hasPrefix("0"), germanBigCityCodes.contains(String(digits.dropFirst().prefix(2))) {
            return "\(digits.prefix(3)) \(digits.dropFirst(3))"
        }
        return trimmed
    }

    /// Splits international digits (without `+`/`00`) into country code and national part using the
    /// built-in code table; unknown codes fall back to three digits.
    static func splitCountryCode(_ digits: String) -> (countryCode: String, national: String)? {
        guard digits.count >= 5 else { return nil }
        let countryCode: String
        if oneDigitCodes.contains(String(digits.prefix(1))) {
            countryCode = String(digits.prefix(1))
        } else if twoDigitCodes.contains(String(digits.prefix(2))) {
            countryCode = String(digits.prefix(2))
        } else {
            countryCode = String(digits.prefix(3))
        }
        return (countryCode, String(digits.dropFirst(countryCode.count)))
    }

    private static func formatInternational(_ digits: String) -> String? {
        guard digits.count >= 7, digits.count <= 15 else { return nil }
        guard let (countryCode, national) = splitCountryCode(digits) else { return nil }
        guard national.count >= 4 else { return nil }
        if countryCode == "1", national.count == 10 {
            let area = national.prefix(3)
            let exchange = national.dropFirst(3).prefix(3)
            let line = national.dropFirst(6)
            return "+1 (\(area)) \(exchange)-\(line)"
        }
        if countryCode == "49" {
            let lead = String(national.prefix(2))
            if germanMobilePrefixes.contains(lead) { return "+49 \(national.prefix(3)) \(national.dropFirst(3))" }
            if germanBigCityCodes.contains(lead) { return "+49 \(lead) \(national.dropFirst(2))" }
            return "+49 \(national)"
        }
        return "+\(countryCode) \(national.prefix(3)) \(national.dropFirst(3))"
    }

    /// Key for matching a number against contacts: the last nine digits (or all digits when
    /// there are fewer), so `+49 170 1234567`, `0170 1234567` and `00491701234567` agree.
    /// Numbers with fewer than seven digits are not matched.
    static func matchKey(_ raw: String) -> String? {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(9))
    }
}
