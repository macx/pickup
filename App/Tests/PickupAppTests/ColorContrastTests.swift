import AppKit
import SwiftUI
import XCTest
@testable import Pickup

/// White symbols on the accept/call and warning circles need at least 3:1 (WCAG 1.4.11).
final class ColorContrastTests: XCTestCase {
    private func luminance(_ color: Color, dark: Bool = false) throws -> Double {
        var resolved: NSColor?
        try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let rgb = try XCTUnwrap(resolved)
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

    // MARK: Dialer list (WCAG 1.4.3 text 4.5:1, 1.4.11 selection outline 3:1)

    private static let lightBackgrounds: [UInt32] = [0xFFFFFF, 0xF0F0F0, 0xE4E4E4]
    private static let darkBackgrounds: [UInt32] = [0x1E1E1E, 0x2A2A2A, 0x363636]

    private func ratio(_ color: Color, dark: Bool, on background: UInt32) throws -> Double {
        let bg = Color.adaptive(light: background, dark: background)
        let a = try luminance(color, dark: dark), b = try luminance(bg, dark: dark)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The selection fill (15 % over the background), as the background of a selected row.
    private func selectedBackground(_ background: UInt32, dark: Bool) -> UInt32 {
        let fill: UInt32 = dark ? 0x4DA3FF : 0x0064E1
        func channel(_ shift: UInt32) -> UInt32 {
            let f = Double((fill >> shift) & 0xFF), b = Double((background >> shift) & 0xFF)
            return UInt32((f * 0.15 + b * 0.85).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    func testDialerListTextReachesFourAndAHalfToOne() throws {
        for (dark, backgrounds) in [(false, Self.lightBackgrounds), (true, Self.darkBackgrounds)] {
            for background in backgrounds {
                for surface in [background, selectedBackground(background, dark: dark)] {
                    XCTAssertGreaterThanOrEqual(try ratio(.missedRed, dark: dark, on: surface), 4.5, "missed red on \(String(surface, radix: 16))")
                    XCTAssertGreaterThanOrEqual(try ratio(.rowSubtitle, dark: dark, on: surface), 4.5, "subtitle on \(String(surface, radix: 16))")
                }
            }
        }
    }

    func testSelectionOutlineReachesThreeToOne() throws {
        for (dark, backgrounds) in [(false, Self.lightBackgrounds), (true, Self.darkBackgrounds)] {
            for background in backgrounds {
                XCTAssertGreaterThanOrEqual(try ratio(.selectionRing, dark: dark, on: background), 3)
                XCTAssertGreaterThanOrEqual(try ratio(.selectionRing, dark: dark, on: selectedBackground(background, dark: dark)), 3)
            }
        }
    }
}
