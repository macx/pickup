import XCTest
@testable import Pickup

final class EndedCallPresentationTests: XCTestCase {
    /// Hung up or cancelled on this Mac: the HUD closes as soon as the phone confirms, no "ended" state.
    func testACallEndedOnTheMacClosesTheHUD() {
        XCTAssertFalse(EndedCallPresentation.showsEndedState(reasonEndedOnMac: true, isOutgoing: true, wasConnected: true, failedOrLinkLost: false))
        XCTAssertFalse(EndedCallPresentation.showsEndedState(reasonEndedOnMac: true, isOutgoing: false, wasConnected: true, failedOrLinkLost: false))
    }

    /// Ended by the other side, busy, failed or link lost: the HUD explains what happened.
    func testOtherEndsShowTheEndedState() {
        XCTAssertTrue(EndedCallPresentation.showsEndedState(reasonEndedOnMac: false, isOutgoing: false, wasConnected: true, failedOrLinkLost: false))
        XCTAssertTrue(EndedCallPresentation.showsEndedState(reasonEndedOnMac: false, isOutgoing: true, wasConnected: false, failedOrLinkLost: false))
        XCTAssertTrue(EndedCallPresentation.showsEndedState(reasonEndedOnMac: false, isOutgoing: false, wasConnected: false, failedOrLinkLost: true))
    }

    /// An incoming call that was never answered here (missed, declined) has no HUD at all.
    func testAnUnansweredIncomingCallShowsNoEndedState() {
        XCTAssertFalse(EndedCallPresentation.showsEndedState(reasonEndedOnMac: false, isOutgoing: false, wasConnected: false, failedOrLinkLost: false))
    }
}
