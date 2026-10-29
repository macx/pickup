import Foundation
import PickupCore

/// One selectable row of the dialer, with the trust decision made once, here, so it can be tested.
struct DialerRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case call(DialNumber)
        case contact(ContactSearchResult)
        /// A recent call; `number` is nil when the entry has no dialable number (e.g. withheld).
        case recent(CallHistoryEntry, number: DialNumber?, list: CallHistoryList)
    }

    var kind: Kind
    var id: String
    /// Whether `dial(_:allowServiceCode:)` may be told to accept `*`/`#` codes for this row.
    var allowServiceCode: Bool
    /// A service code that did not come from the keypad (typed or pasted text): needs a second,
    /// explicit confirmation before it is dialed.
    var requiresConfirmation: Bool
}

enum DialerRows {
    /// `fromKeypad`: the text was built only by tapping the keypad (not typed, pasted or edited).
    /// - Contact rows are never trusted (`allowServiceCode == false`).
    /// - Text containing letters never offers a "Call …" row.
    /// - A service code offers a call row that is trusted only when it came from the keypad;
    ///   otherwise the row is flagged `requiresConfirmation`.
    static func rows(for text: String, contacts: [ContactSearchResult], fromKeypad: Bool) -> [DialerRow] {
        var rows: [DialerRow] = []
        if !text.contains(where: \.isLetter), let number = DialNumber(text) {
            rows.append(DialerRow(kind: .call(number), id: "call|\(number.value)",
                                  allowServiceCode: number.isServiceCode && fromKeypad,
                                  requiresConfirmation: number.isServiceCode && !fromKeypad))
        }
        rows += contacts.map {
            DialerRow(kind: .contact($0), id: $0.id, allowServiceCode: false, requiresConfirmation: false)
        }
        return rows
    }

    /// Rows for the recent calls of one list. Numbers from the phone are untrusted: a service code
    /// is never allowed directly and needs the second confirmation, like typed text.
    static func recentRows(_ entries: [CallHistoryEntry], list: CallHistoryList) -> [DialerRow] {
        entries.enumerated().map { index, entry in
            let number = DialNumber(entry.number)
            return DialerRow(kind: .recent(entry, number: number, list: list), id: "recent|\(list.rawValue)|\(index)",
                             allowServiceCode: false, requiresConfirmation: number?.isServiceCode ?? false)
        }
    }

    /// The number the keypad's call button puts into the empty field (redial): the newest dialed call.
    static func redialNumber(in entries: [CallHistoryEntry]) -> String? {
        entries.first { DialNumber($0.number) != nil }?.number
    }
}
