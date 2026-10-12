import XCTest

/// The first test to run: proves the Accessibility permission works and the popover opens.
@MainActor
final class SmokeTests: PickupUITestCase {
    func testPopoverOpensFromTheStatusItem() throws {
        XCTAssertTrue(AXIsProcessTrusted(), "Accessibility permission missing")
        try launch("idle")
        openPopover()
        XCTAssertTrue(waitExists("search-field"))
        XCTAssertTrue(waitExists("keypad-toggle"))
        XCTAssertTrue(waitExists("more-button"))
        closePopoverIfOpen()
        XCTAssertTrue(waitGone("popover-root"), "Esc closes the popover")
    }
}
