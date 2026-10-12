import AppKit
import XCTest
@testable import Pickup

final class PanelGeometryTests: XCTestCase {
    func testIdenticalAndTinyChangesDoNotResize() {
        XCTAssertFalse(PanelGeometry.needsResize(from: CGSize(width: 344, height: 230), to: CGSize(width: 344, height: 230)))
        XCTAssertFalse(PanelGeometry.needsResize(from: CGSize(width: 344, height: 230), to: CGSize(width: 344.3, height: 229.8)))
        XCTAssertTrue(PanelGeometry.needsResize(from: CGSize(width: 344, height: 230), to: CGSize(width: 344, height: 231)))
    }

    func testAnchoredFrameKeepsTopRightCorner() {
        let current = NSRect(x: 1300, y: 700, width: 344, height: 230)
        let grown = PanelGeometry.anchoredFrame(current: current, newSize: CGSize(width: 344, height: 272))
        XCTAssertEqual(grown.maxX, current.maxX)
        XCTAssertEqual(grown.maxY, current.maxY)
        XCTAssertEqual(grown.size, CGSize(width: 344, height: 272))
        let narrower = PanelGeometry.anchoredFrame(current: grown, newSize: CGSize(width: 300, height: 100))
        XCTAssertEqual(narrower.maxX, current.maxX)
        XCTAssertEqual(narrower.maxY, current.maxY)
    }

    func testCornerFrameSitsInTopRightOfVisibleArea() {
        let area = NSRect(x: 0, y: 0, width: 1728, height: 1050)
        let frame = PanelGeometry.cornerFrame(size: CGSize(width: 444, height: 114), in: area)
        XCTAssertEqual(frame.maxX, 1728 - 12)
        XCTAssertEqual(frame.maxY, 1050 - 12)
    }
}
