import XCTest
@testable import Pickup

final class PopoverWidthTests: XCTestCase {
    func testWidthStaysBetweenTheMinimumAndTwiceTheMinimum() {
        XCTAssertEqual(PopoverWidth.maximum, 2 * PopoverWidth.minimum)
        XCTAssertEqual(PopoverWidth.clamped(120), PopoverWidth.minimum)
        XCTAssertEqual(PopoverWidth.clamped(10_000), PopoverWidth.maximum)
        XCTAssertEqual(PopoverWidth.clamped(420.4), 420)
        XCTAssertEqual(PopoverWidth.clamped(.nan), PopoverWidth.minimum, "a broken saved value falls back to the minimum")
    }

    func testDraggingAnEdgeChangesTheWidthByTwiceTheDistance() {
        XCTAssertEqual(PopoverWidth.resized(from: 300, outwardDelta: 40), 380)
        XCTAssertEqual(PopoverWidth.resized(from: 400, outwardDelta: -30), 340)
        XCTAssertEqual(PopoverWidth.resized(from: 300, outwardDelta: -30), 300)
    }
}
