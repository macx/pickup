import Foundation

/// Unsolicited result codes and responses sent by the phone (audio gateway) over HFP.
public enum HFPEvent: Equatable, Sendable {
    case ring
    case callerID(number: String)
    /// `+CCWA`: a second call is waiting while a call is active. Number may be empty (withheld).
    case callWaiting(number: String)
    /// `+CIEV: <index>,<value>`. The index meaning comes from `+CIND=?` (see `HFPIndicatorMap`).
    case indicator(index: Int, value: Int)
    /// One `+CLCC` entry.
    case currentCall(HFPCall)
    case ok
    case error
    case cmeError(Int)
    case cmsError(Int)
    case callFailure(String)
    case unknown(String)

    /// The final result code this event represents, if any.
    public var finalResult: CommandResult? {
        switch self {
        case .ok: return .ok
        case .error: return .error
        case .cmeError(let code): return .cmeError(code)
        case .cmsError(let code): return .cmsError(code)
        case .callFailure(let text): return .callFailure(text)
        default: return nil
        }
    }
}

/// Parses single AT response lines from the audio gateway.
public enum ATParser {
    static let callFailureCodes: Set<String> = ["NO CARRIER", "BUSY", "NO ANSWER", "DELAYED", "BLACKLISTED"]

    public static func parse(_ line: String) -> HFPEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmed {
        case "RING": return .ring
        case "OK": return .ok
        case "ERROR": return .error
        default: break
        }
        if callFailureCodes.contains(trimmed) {
            return .callFailure(trimmed)
        }

        if let fields = fields(of: trimmed, prefix: "+CME ERROR:"),
           let code = fields.first.flatMap({ Int($0) }) {
            return .cmeError(code)
        }

        if let fields = fields(of: trimmed, prefix: "+CMS ERROR:"),
           let code = fields.first.flatMap({ Int($0) }) {
            return .cmsError(code)
        }

        if let fields = fields(of: trimmed, prefix: "+CLIP:") {
            return .callerID(number: fields.first ?? "")
        }

        if let fields = fields(of: trimmed, prefix: "+CCWA:") {
            return .callWaiting(number: fields.first ?? "")
        }

        if let fields = fields(of: trimmed, prefix: "+CIEV:"),
           fields.count == 2, let index = Int(fields[0]), let value = Int(fields[1]) {
            return .indicator(index: index, value: value)
        }

        if trimmed.hasPrefix("+CLCC:"), let call = parseCLCC(trimmed) {
            return .currentCall(call)
        }

        return .unknown(trimmed)
    }

    /// Parses `+CLCC: <idx>,<dir>,<stat>,<mode>,<mpty>[,<number>,<type>[,<alpha>[,<priority>]]]`.
    public static func parseCLCC(_ line: String) -> HFPCall? {
        guard let fields = fields(of: line, prefix: "+CLCC:"), fields.count >= 5,
              let index = Int(fields[0]),
              let directionValue = Int(fields[1]),
              let statusValue = Int(fields[2]), let status = CallListStatus(rawValue: statusValue),
              let mode = Int(fields[3]),
              let multiparty = Int(fields[4])
        else { return nil }

        let number = fields.count > 5 ? fields[5] : nil
        let numberType = fields.count > 6 ? Int(fields[6]) : nil
        return HFPCall(
            index: index,
            direction: directionValue == 1 ? .incoming : .outgoing,
            status: status,
            mode: mode,
            isMultiparty: multiparty == 1,
            number: number,
            numberType: numberType
        )
    }

    /// Splits the arguments after `prefix` at commas outside double quotes and strips the quotes.
    /// Returns nil if the line does not start with `prefix`.
    static func fields(of line: String, prefix: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let body = trimmed.dropFirst(prefix.count)

        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in body {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        if fields == [""] { return [] }
        return fields
    }
}
