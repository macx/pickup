import AppKit
import XCTest
@testable import Pickup

final class AppShortcutTests: XCTestCase {
    func testCommandShortcuts() {
        XCTAssertEqual(AppShortcut.match(characters: ",", modifiers: .command), .openSettings)
        XCTAssertEqual(AppShortcut.match(characters: "q", modifiers: .command), .quit)
        XCTAssertEqual(AppShortcut.match(characters: "Q", modifiers: .command), .quit)
        XCTAssertEqual(AppShortcut.match(characters: "w", modifiers: .command), .closeWindow)
    }

    func testIgnoresCapsLockAndNumericPadFlags() {
        XCTAssertEqual(AppShortcut.match(characters: ",", modifiers: [.command, .capsLock]), .openSettings)
    }

    func testOtherModifierCombinationsAreNotOurs() {
        XCTAssertNil(AppShortcut.match(characters: ",", modifiers: []))
        XCTAssertNil(AppShortcut.match(characters: ",", modifiers: [.command, .shift]))
        XCTAssertNil(AppShortcut.match(characters: "q", modifiers: [.command, .option]))
        XCTAssertNil(AppShortcut.match(characters: "w", modifiers: .control))
        XCTAssertNil(AppShortcut.match(characters: "a", modifiers: .command))
        XCTAssertNil(AppShortcut.match(characters: nil, modifiers: .command))
    }
}
