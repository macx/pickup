import Foundation

/// A call list kept by the phone, read over HFP as a phonebook memory (`AT+CPBS`, 3GPP TS 27.007).
/// Android serves these from its call log, newest first, once the phone has granted the paired Mac
/// access to contacts and call history.
public enum CallHistoryList: String, CaseIterable, Equatable, Hashable, Sendable {
    /// `"DC"`: dialled calls.
    case dialed = "DC"
    /// `"RC"`: received (answered) calls.
    case received = "RC"
    /// `"MC"`: missed calls.
    case missed = "MC"
}

/// One call of a call list. Contains personal data: its descriptions never print number or name.
public struct CallHistoryEntry: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// As the phone reported it; empty when the number was withheld or unknown.
    public var number: String
    /// The name the phone attached (from its contacts), if any.
    public var name: String?
    /// When the call started. Only known for calls Pickup saw itself (the phone sends no dates).
    public var date: Date?
    /// Consecutive calls with the same number, shown as one entry.
    public var count: Int

    public init(number: String, name: String? = nil, date: Date? = nil, count: Int = 1) {
        self.number = number
        self.name = name
        self.date = date
        self.count = count
    }

    public var description: String {
        "CallHistoryEntry(number: \(number.isEmpty ? "none" : "<redacted>"), name: \(name == nil ? "none" : "<redacted>"), count: \(count))"
    }

    public var debugDescription: String { description }
}

/// The recent calls the UI shows: the phone's lists when it shares them, otherwise the calls Pickup
/// saw since it was launched (kept in memory only).
public struct CallHistory: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Read from the phone.
        case phone
        /// Calls seen by Pickup since launch.
        case session
    }

    /// Lists read from the phone, newest first. A list is missing until it was read successfully.
    public private(set) var phoneLists: [CallHistoryList: [CallHistoryEntry]] = [:]
    /// Calls seen by Pickup since launch, newest first.
    public private(set) var sessionCalls: [CallHistoryList: [CallHistoryEntry]] = [:]
    /// The last attempt to read a list from the phone failed (refused, unsupported or no answer).
    public private(set) var phoneRefused = false
    /// Lists requested from the phone and not answered yet.
    public private(set) var pending: Set<CallHistoryList> = []

    /// Upper bound for the session lists.
    public static let sessionLimit = 50

    public init() {}

    public var isLoading: Bool { !pending.isEmpty }

    public func source(_ list: CallHistoryList) -> Source {
        phoneLists[list] != nil ? .phone : .session
    }

    /// What to show for `list`: consecutive calls with the same number are merged into one entry.
    public func entries(_ list: CallHistoryList) -> [CallHistoryEntry] {
        Self.collapsed(phoneLists[list] ?? sessionCalls[list] ?? [])
    }

    /// Records a call that ended (session list). Failed dial attempts never reached the phone's log.
    public mutating func record(_ call: CallInfo) {
        guard let list = Self.list(for: call) else { return }
        let entry = CallHistoryEntry(number: call.callerID.number ?? "", date: call.startedAt)
        var calls = sessionCalls[list] ?? []
        calls.insert(entry, at: 0)
        sessionCalls[list] = Array(calls.prefix(Self.sessionLimit))
    }

    mutating func requested(_ list: CallHistoryList) {
        pending.insert(list)
    }

    /// The phone answered a request for `list`; nil = it refused or did not answer.
    mutating func received(_ list: CallHistoryList, entries: [CallHistoryEntry]?) {
        pending.remove(list)
        if let entries {
            phoneLists[list] = entries
            phoneRefused = false
        } else {
            phoneRefused = true
        }
    }

    /// The link went down: answers still outstanding will never arrive.
    mutating func cancelPending() {
        pending.removeAll()
    }

    /// Which list a finished call belongs to. Declined calls count as missed (nobody talked).
    static func list(for call: CallInfo) -> CallHistoryList? {
        switch (call.direction, call.endReason) {
        case (_, .failed?), (_, nil):
            return nil
        case (.outgoing, _):
            return .dialed
        case (.incoming, .missed?), (.incoming, .declined?):
            return .missed
        case (.incoming, _):
            return call.connectedAt == nil ? .missed : .received
        case (.unknown, _):
            return nil
        }
    }

    /// Merges runs of the same number (compared by digits) into one entry with a count.
    static func collapsed(_ entries: [CallHistoryEntry]) -> [CallHistoryEntry] {
        var result: [CallHistoryEntry] = []
        for entry in entries {
            if var last = result.last, !entry.number.isEmpty, digits(last.number) == digits(entry.number) {
                last.count += entry.count
                if last.name == nil { last.name = entry.name }
                result[result.count - 1] = last
            } else {
                result.append(entry)
            }
        }
        return result
    }

    private static func digits(_ number: String) -> String {
        String(number.filter { $0.isASCII && ($0.isNumber || $0 == "+" || $0 == "*" || $0 == "#") })
    }
}
