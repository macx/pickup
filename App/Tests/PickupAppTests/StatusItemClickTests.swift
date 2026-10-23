import XCTest
@testable import Pickup

final class StatusItemClickTests: XCTestCase {
    func testWithoutCallTheClickTogglesThePopover() {
        XCTAssertEqual(StatusItemClick.action(popoverShown: false, callIsLive: false, callPanelVisible: false), .showPopover)
        XCTAssertEqual(StatusItemClick.action(popoverShown: true, callIsLive: false, callPanelVisible: false), .closePopover)
    }

    func testDuringACallTheClickFocusesTheCallPanel() {
        XCTAssertEqual(StatusItemClick.action(popoverShown: false, callIsLive: true, callPanelVisible: true), .focusCallPanel)
    }

    func testAnOpenPopoverStillClosesDuringACall() {
        XCTAssertEqual(StatusItemClick.action(popoverShown: true, callIsLive: true, callPanelVisible: true), .closePopover)
    }

    /// An ended call (panel shows "Call Ended") or a call without a visible panel keeps the popover reachable.
    func testWithoutLiveCallOrVisiblePanelThePopoverOpens() {
        XCTAssertEqual(StatusItemClick.action(popoverShown: false, callIsLive: false, callPanelVisible: true), .showPopover)
        XCTAssertEqual(StatusItemClick.action(popoverShown: false, callIsLive: true, callPanelVisible: false), .showPopover)
    }
}
