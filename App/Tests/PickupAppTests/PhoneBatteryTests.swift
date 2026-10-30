import PickupCore
import XCTest
@testable import Pickup

final class PhoneBatteryTests: XCTestCase {
    func testLevelsMapToTwentyPercentSteps() {
        XCTAssertEqual((0...5).map { PhoneBattery.percent(level: $0) }, [0, 20, 40, 60, 80, 100])
        XCTAssertEqual(PhoneBattery.percent(level: 9), 100, "out-of-range values from the phone are clamped")
        XCTAssertEqual(PhoneBattery.percent(level: -1), 0)
        XCTAssertEqual(PhoneBattery.fraction(level: 3), 0.6, accuracy: 0.001)
    }

    func testPercentTextFollowsTheLocale() {
        XCTAssertEqual(PhoneBattery.percentText(level: 3, locale: Locale(identifier: "en_US")), "60%")
        XCTAssertEqual(PhoneBattery.percentText(level: 3, locale: Locale(identifier: "de_DE")), "60\u{00A0}%")
    }
}

final class MissedCallsTests: XCTestCase {
    func testOnlyUnansweredIncomingCallsCountAsMissed() {
        XCTAssertTrue(MissedCalls.isMissed(direction: .incoming, endReason: .missed))
        XCTAssertFalse(MissedCalls.isMissed(direction: .incoming, endReason: .declined), "declining on this Mac is a choice")
        XCTAssertFalse(MissedCalls.isMissed(direction: .outgoing, endReason: .unanswered))
        XCTAssertFalse(MissedCalls.isMissed(direction: .incoming, endReason: .remoteEnded))
    }
}
