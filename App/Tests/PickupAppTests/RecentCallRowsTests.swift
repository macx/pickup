import PickupCore
import XCTest
@testable import Pickup

/// Recent call rows: numbers from the phone are untrusted and never dial a service code directly.
final class RecentCallRowsTests: XCTestCase {
    func testRecentRowsCarryTheirNumberAndAStableID() {
        let rows = DialerRows.recentRows([CallHistoryEntry(number: "+49300000123", name: "Jane Doe"),
                                          CallHistoryEntry(number: "")], list: .dialed)
        XCTAssertEqual(rows.map(\.id), ["recent|DC|0", "recent|DC|1"])
        guard case .recent(_, let number, let list) = rows[0].kind else { return XCTFail("not a recent row") }
        XCTAssertEqual(number?.value, "+49300000123")
        XCTAssertEqual(list, .dialed)
        guard case .recent(_, let withheld, _) = rows[1].kind else { return XCTFail("not a recent row") }
        XCTAssertNil(withheld, "a withheld caller cannot be called back")
        XCTAssertFalse(rows.contains { $0.allowServiceCode })
    }

    func testServiceCodeFromThePhoneNeedsConfirmation() {
        let rows = DialerRows.recentRows([CallHistoryEntry(number: "*#21#")], list: .dialed)
        XCTAssertTrue(rows[0].requiresConfirmation)
        XCTAssertFalse(rows[0].allowServiceCode)
    }

    func testRedialUsesTheNewestDialableNumber() {
        XCTAssertEqual(DialerRows.redialNumber(in: [CallHistoryEntry(number: ""), CallHistoryEntry(number: "+49300000123"),
                                                     CallHistoryEntry(number: "+49300000456")]), "+49300000123")
        XCTAssertNil(DialerRows.redialNumber(in: []))
    }

    func testCopyableNumber() {
        let rows = DialerRows.recentRows([CallHistoryEntry(number: "+49300000123", name: "Jane Doe"), CallHistoryEntry(number: "")],
                                         list: .missed)
        XCTAssertEqual(rows.map(\.copyableNumber), ["+49300000123", nil], "a withheld caller has nothing to copy")
        XCTAssertEqual(DialerRows.rows(for: "+49 30 0000123", contacts: [], fromKeypad: false).first?.copyableNumber,
                       DialNumber("+49 30 0000123")?.value)
    }

    func testTypeAheadAcceptsOnlyPrintableText() {
        for text in ["J", "j", "5", "+", "*", "#", "ä"] { XCTAssertTrue(TypeAhead.accepts(text), text) }
        for text in ["", " ", "\t", "\r", "\u{1B}", "\u{F700}", "\u{F701}", "\u{7F}"] {
            XCTAssertFalse(TypeAhead.accepts(text), text.debugDescription)
        }
    }
}
