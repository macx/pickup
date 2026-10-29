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
}
