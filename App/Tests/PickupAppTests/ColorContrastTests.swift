import AppKit
import SwiftUI
import XCTest
@testable import Pickup

/// White symbols on the accept/call and warning circles need at least 3:1 (WCAG 1.4.11).
final class ColorContrastTests: XCTestCase {
    private func luminance(_ color: Color) throws -> Double {
        let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private func contrastWithWhite(_ color: Color) throws -> Double {
        1.05 / (try luminance(color) + 0.05)
    }

    func testWhiteSymbolsOnCallGreenAndWarningOrangeReachThreeToOne() throws {
        XCTAssertGreaterThanOrEqual(try contrastWithWhite(.callGreen), 3)
        XCTAssertGreaterThanOrEqual(try contrastWithWhite(.warningOrange), 3)
    }
}
