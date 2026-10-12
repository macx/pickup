import AppKit
import XCTest
@testable import Pickup

final class KeyComboTests: XCTestCase {
    private func combo(_ code: UInt32, _ name: String, _ mods: KeyCombo.Modifiers) -> KeyCombo {
        KeyCombo(keyCode: code, modifiers: mods, keyName: name)
    }

    func testValidityNeedsCommandControlOrOption() {
        XCTAssertTrue(combo(35, "P", [.control, .option]).isValid)
        XCTAssertTrue(combo(35, "P", [.command]).isValid)
        XCTAssertFalse(combo(35, "P", []).isValid)
        XCTAssertFalse(combo(35, "P", [.shift]).isValid)
    }

    func testDisplayUsesSystemModifierOrder() {
        XCTAssertEqual(combo(35, "P", [.control, .option]).displayString, "⌃⌥P")
        XCTAssertEqual(combo(35, "P", [.command, .shift, .option, .control]).displayString, "⌃⌥⇧⌘P")
        XCTAssertEqual(combo(122, "F1", [.command]).displayString, "⌘F1")
    }

    func testCarbonModifierMask() {
        XCTAssertEqual(combo(35, "P", [.command]).carbonModifiers, 0x0100)
        XCTAssertEqual(combo(35, "P", [.control, .option]).carbonModifiers, 0x1000 | 0x0800)
        XCTAssertEqual(combo(35, "P", [.shift, .command]).carbonModifiers, 0x0200 | 0x0100)
    }

    func testMakeFromEvent() {
        let c = KeyCombo.make(keyCode: 35, characters: "p", flags: [.control, .option, .capsLock])
        XCTAssertEqual(c, combo(35, "P", [.control, .option]))
        XCTAssertEqual(KeyCombo.make(keyCode: 49, characters: " ", flags: .command)?.keyName, "␣")
        XCTAssertEqual(KeyCombo.make(keyCode: 96, characters: nil, flags: .command)?.keyName, "F5")
        XCTAssertNil(KeyCombo.make(keyCode: 200, characters: nil, flags: .command))
    }

    func testEncodingRoundTrip() throws {
        let original = combo(35, "P", [.control, .option])
        let data = try XCTUnwrap(original.encoded())
        XCTAssertEqual(KeyCombo.decode(data), original)
    }

    func testDecodeRejectsGarbageAndInvalidCombos() throws {
        XCTAssertNil(KeyCombo.decode(nil))
        XCTAssertNil(KeyCombo.decode(Data("nope".utf8)))
        let weak = try XCTUnwrap(combo(35, "P", [.shift]).encoded())
        XCTAssertNil(KeyCombo.decode(weak))   // a stored combo without ⌘/⌃/⌥ is ignored
    }

    func testSystemShortcutDetection() {
        XCTAssertTrue(combo(49, "␣", [.command]).isLikelySystemShortcut)
        XCTAssertTrue(combo(12, "Q", [.command]).isLikelySystemShortcut)
        XCTAssertFalse(combo(35, "P", [.control, .option]).isLikelySystemShortcut)
    }
}
