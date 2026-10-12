import Foundation

/// A completed AT command: what was sent, the information responses that belong to it, and its
/// final result code.
public struct ATExchange: Equatable, Sendable {
    public let command: HFPCommand
    /// Information response lines for this command (e.g. the `+CLCC:` lines of `AT+CLCC`).
    public let responses: [String]
    public let result: CommandResult

    /// The current call list, if this exchange was `AT+CLCC`.
    public var currentCalls: [HFPCall] {
        responses.compactMap(ATParser.parseCLCC)
    }
}

/// Correlates the raw AT lines in both directions into command/response exchanges.
///
/// HFP is strictly serialised: the HF sends one command and waits for its final result code
/// (`OK`, `ERROR`, `+CME ERROR`, `+CMS ERROR`) before sending the next one (HFP 1.8, section
/// 4.34.1). So the next final result always belongs to the oldest outstanding command.
/// Information responses are attached to that command when their prefix matches it (`+CLCC:` for
/// `AT+CLCC`); every other line is unsolicited (`+CIEV`, `RING`, `+CLIP`, `+CCWA`, `+BSIR`, ...).
///
/// A missing reply must not shift every later result onto the wrong command, so the tracker
/// resynchronises:
/// - a write that failed (`writeFailed()`) never gets a reply: its entry is dropped;
/// - an information response that belongs to a *later* pending command discards the older ones;
/// - entries older than `responseTimeout` are discarded before the next line is matched.
/// Discarded commands are reported as `.discarded`; they never complete.
///
/// Transport-neutral: fed with lines, no I/O. Not thread-safe.
public struct ATExchangeTracker {
    public enum Output: Equatable, Sendable {
        /// A line that does not belong to a command (or a final result with no command pending).
        case unsolicited(HFPEvent)
        /// An information response collected for the oldest pending command.
        case response(HFPEvent)
        case completed(ATExchange)
        /// A command that will never be matched with a reply (lost, timed out or failed to send).
        case discarded(HFPCommand)
    }

    private struct Pending {
        let command: HFPCommand
        let responsePrefix: String?
        let sentAt: Date
        var responses: [String] = []
    }

    /// Commands still waiting for their final result. A queue in case writes were pipelined anyway.
    private var pending: [Pending] = []
    /// Upper bound so a missed final result cannot grow the queue forever.
    public static let maximumPending = 8
    /// The AG answers within milliseconds (phase 0: < 1.5 s even for ATD); older entries are lost.
    public var responseTimeout: TimeInterval

    public init(responseTimeout: TimeInterval = 5) {
        self.responseTimeout = responseTimeout
    }

    /// Number of commands sent but not yet completed.
    public var pendingCount: Int { pending.count }

    /// Records a command line written by the Mac (without CR/LF).
    @discardableResult
    public mutating func outgoing(_ line: String, at date: Date = Date()) -> [Output] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("AT") else { return [] }
        var outputs = expire(at: date)
        pending.append(Pending(
            command: HFPCommand(atCommand: trimmed),
            responsePrefix: HFPCommand.responsePrefix(of: trimmed),
            sentAt: date
        ))
        while pending.count > Self.maximumPending {
            outputs.append(.discarded(pending.removeFirst().command))
        }
        return outputs
    }

    /// The most recent write did not reach the phone, so it will never be answered.
    @discardableResult
    public mutating func writeFailed() -> [Output] {
        guard let last = pending.popLast() else { return [] }
        return [.discarded(last.command)]
    }

    /// Feeds one line received from the phone and returns what it means.
    public mutating func incoming(_ line: String, at date: Date = Date()) -> [Output] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = ATParser.parse(trimmed)
        var outputs = expire(at: date)

        if let result = event.finalResult {
            guard !pending.isEmpty else { return outputs + [.unsolicited(event)] }
            let done = pending.removeFirst()
            return outputs + [.completed(ATExchange(command: done.command, responses: done.responses, result: result))]
        }

        let upper = trimmed.uppercased()
        if let index = pending.firstIndex(where: { entry in
            entry.responsePrefix.map { upper.hasPrefix($0 + ":") } ?? false
        }) {
            // Commands before the one this response belongs to lost their replies.
            for _ in 0..<index {
                outputs.append(.discarded(pending.removeFirst().command))
            }
            pending[0].responses.append(trimmed)
            return outputs + [.response(event)]
        }

        return outputs + [.unsolicited(event)]
    }

    /// Drops all outstanding commands, e.g. when the link goes down.
    public mutating func reset() {
        pending.removeAll()
    }

    private mutating func expire(at date: Date) -> [Output] {
        var outputs: [Output] = []
        while let first = pending.first, date.timeIntervalSince(first.sentAt) > responseTimeout {
            outputs.append(.discarded(pending.removeFirst().command))
        }
        return outputs
    }
}

/// Maps `+CIEV` indices to indicators, using the order the phone announced in `+CIND=?`.
///
/// IOBluetooth does this mapping internally; this type exists for transports that see raw AT
/// lines only, and for replaying logs in tests.
public struct HFPIndicatorMap: Equatable, Sendable {
    /// Indicator names in announcement order; index 1 is the first entry.
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }

    /// Parses the `+CIND=?` test response:
    /// `+CIND: ("call",(0,1)),("callsetup",(0-3)),("service",(0-1)),...`
    public init?(testResponse line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+CIND:"), trimmed.contains("(\"") else { return nil }
        var names: [String] = []
        var rest = Substring(trimmed)
        while let open = rest.range(of: "(\"") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: "\"") else { break }
            names.append(String(afterOpen[..<close]).lowercased())
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        guard !names.isEmpty else { return nil }
        self.names = names
    }

    /// Maps `+CIEV: <index>,<value>` (index is 1-based) to an indicator, or nil if unknown.
    public func indicator(index: Int, value: Int) -> HFPIndicator? {
        guard index >= 1, index <= names.count else { return nil }
        switch names[index - 1] {
        case "service": return .service(value != 0)
        case "call": return .call(value != 0)
        case "callsetup", "call_setup": return CallSetupState(rawValue: value).map(HFPIndicator.callSetup)
        case "callheld": return CallHeldState(rawValue: value).map(HFPIndicator.callHeld)
        case "signal": return .signal(value)
        case "roam": return .roaming(value != 0)
        case "battchg": return .battery(value)
        default: return nil
        }
    }

    /// Maps the `+CIND?` read response (`+CIND: 0,0,1,5,0,4,0`) to indicators.
    public func indicators(fromReadResponse line: String) -> [HFPIndicator] {
        guard let fields = ATParser.fields(of: line, prefix: "+CIND:") else { return [] }
        return fields.enumerated().compactMap { offset, field in
            Int(field).flatMap { indicator(index: offset + 1, value: $0) }
        }
    }
}
