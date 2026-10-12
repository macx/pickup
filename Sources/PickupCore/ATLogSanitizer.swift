import Foundation

/// Removes personal data from raw AT lines before they are written to a log.
///
/// Phone numbers are abbreviated later by `PhoneNumberRedaction` (in `DiagnosticLog`); this type
/// handles what that cannot recognise:
/// - contact names the phone attaches to numbers (`+CLIP: "<number>",145,,,"<name>"`, also in
///   `+CCWA`, `+CLCC`, `+CNUM`, `+CPBR`, `+CMT`, `+CMGR`, `+CMGL`): every quoted field except the
///   number becomes `""`;
/// - SMS bodies after `+CMT` / `+CMGR` / `+CMGL` headers: replaced by `<message body removed>`;
/// - DTMF digits (`AT+VTS=5` may be a PIN): logged as `AT+VTS=<digit>`.
///
/// Stateful because a message body is the line *after* its header. Use one instance per
/// direction. Not thread-safe.
public struct ATLogSanitizer {
    public static let removedBody = "<message body removed>"
    public static let hiddenDigit = "<digit>"

    /// Field index of the number to keep, per result code (all other quoted fields are blanked).
    static let numberFieldIndex: [String: Int] = [
        "+CLIP:": 0, "+CCWA:": 0, "+CLCC:": 5, "+CNUM:": 1, "+CPBR:": 1,
        "+CMT:": 0, "+CMGR:": 1, "+CMGL:": 2,
    ]
    static let messageHeaders = ["+CMT:", "+CMGR:", "+CMGL:"]

    private enum BodyState { case none, singleLine, untilFinalResult }
    private var bodyState = BodyState.none

    public init() {}

    /// Sanitises a line sent by the Mac.
    public static func outgoing(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("AT+VTS=") {
            return "AT+VTS=" + hiddenDigit
        }
        return line
    }

    /// Sanitises a line received from the phone.
    public mutating func incoming(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let isHeader = Self.messageHeaders.contains { upper.hasPrefix($0) }

        switch bodyState {
        case .singleLine where !isHeader:
            bodyState = .none
            return Self.removedBody
        case .untilFinalResult where !isHeader:
            if ATParser.parse(trimmed).finalResult != nil {
                bodyState = .none
                return line
            }
            return Self.removedBody
        default:
            break
        }

        if isHeader {
            bodyState = upper.hasPrefix("+CMT:") ? .singleLine : .untilFinalResult
        }
        return Self.blankingNames(in: line)
    }

    /// Blanks every quoted field except the number in result codes that may carry contact names.
    public static func blankingNames(in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (prefix, keep) = numberFieldIndex.first(where: { trimmed.uppercased().hasPrefix($0.key) }) else {
            return line
        }
        // Split at commas outside quotes, keeping the raw field text.
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in trimmed.dropFirst(prefix.count) {
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)

        let blanked = fields.enumerated().map { index, field -> String in
            let value = field.trimmingCharacters(in: .whitespaces)
            guard index != keep, value.hasPrefix("\""), value.count > 2 else { return field }
            let leading = field.prefix { $0 == " " }
            return leading + "\"\""
        }
        return prefix + blanked.joined(separator: ",")
    }
}
