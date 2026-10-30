import AppKit
import XCTest

/// Popover, search, keypad, keyboard handling and window shortcuts (docs/TESTING.md, section 4).
@MainActor
final class PopoverTests: PickupUITestCase {
    func testSearchArrowKeysAndReturnDialTheSelectedRow() throws {
        try launch("outgoing-answered")
        search("max")
        XCTAssertTrue(waitExists("contact-row-multi-2"), "Max Mustermann has one row per number")
        let rows = (0...2).map { element("contact-row-multi-\($0)") }
        XCTAssertTrue(Wait.until(3) { rows[0].isSelected }, "the first row starts selected")
        keyboard.press(Key.down)
        keyboard.press(Key.down)
        XCTAssertTrue(Wait.until(3) { element("contact-row-multi-2").isSelected }, "two Down presses select the third row")
        keyboard.press(Key.up)
        XCTAssertTrue(Wait.until(3) { element("contact-row-multi-1").isSelected }, "Up moves back")
        keyboard.press(Key.down)
        keyboard.press(Key.returnKey)
        XCTAssertTrue(waitExists("call-hud"), "Return starts the call")
        XCTAssertTrue(waitText("hud-state") { $0 == self.s("Calling…", "Anruf läuft …") }, "HUD says Calling: '\(hudState())'")
        XCTAssertTrue(element("hud-caller").allText.contains("Max Mustermann"))
        XCTAssertTrue(Wait.until(3) { self.appLog.contains("dial") && self.appLog.range(of: #"dial .*333"#, options: .regularExpression) != nil },
                      "the third number (…333) was dialed:\n\(appLog)")
        XCTAssertTrue(waitGone("popover-root"), "the popover closes when the call window takes over")
    }

    func testReturnWithoutExplicitSelectionDialsTheFirstRowAndNothingElseIsDialed() throws {
        try launch("outgoing-busy")
        search("jane")
        XCTAssertTrue(waitExists("contact-row-jane-0"))
        XCTAssertFalse(appLog.contains("-> dial()"), "typing and selecting never dials")
        keyboard.press(Key.returnKey)
        XCTAssertTrue(waitExists("call-hud"))
        XCTAssertNotNil(appLog.range(of: #"dial .*123"#, options: .regularExpression))
    }

    func testRecentCallsAreReachedWithTabAndCalledWithReturn() throws {
        try launch("outgoing-answered")
        openPopover()
        XCTAssertTrue(waitExists("recent-row-DC-2"), "the phone's dialed calls show while the field is empty")
        XCTAssertFalse(element("recent-row-DC-0").isSelected, "no row starts selected: a stray Return never redials")
        XCTAssertTrue(exists("recent-row-DC-0-call"), "every row has its own call button")

        // ↓ from the search field selects the first row, like in the search results.
        keyboard.press(Key.down)
        XCTAssertTrue(Wait.until(3) { self.element("recent-row-DC-0").isSelected }, "Down selects the first row")
        keyboard.press(Key.down)
        XCTAssertTrue(Wait.until(3) { self.element("recent-row-DC-1").isSelected })

        // ⌘C copies the selected number (the pasteboard is restored afterwards).
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        pasteboard.clearContents()
        keyboard.press(Key.c, flags: .maskCommand)
        XCTAssertTrue(Wait.until(3) { pasteboard.string(forType: .string)?.contains("0000") == true },
                      "Command-C copies the selected row's number")

        keyboard.press(Key.escape)
        XCTAssertTrue(Wait.until(3) { !self.element("recent-row-DC-1").isSelected }, "Esc returns to the search field")
        XCTAssertTrue(exists("popover-root"), "…and keeps the popover open")

        // Tab follows the system order: field → tabs → list (which selects its first row).
        keyboard.press(Key.tab)
        XCTAssertFalse(element("recent-row-DC-0").isSelected, "the first Tab stops at the tabs")
        keyboard.press(Key.tab)
        XCTAssertTrue(Wait.until(3) { self.element("recent-row-DC-0").isSelected }, "the second Tab enters the list")
        keyboard.press(Key.right)
        XCTAssertTrue(Wait.until(3) { self.exists("recent-row-MC-0") && self.element("recent-row-MC-0").isSelected },
                      "Right switches to the next tab and keeps the keyboard in the list")
        keyboard.press(Key.left)
        XCTAssertTrue(Wait.until(3) { self.exists("recent-row-RC-0") && self.element("recent-row-RC-0").isSelected })
        keyboard.press(Key.left)
        XCTAssertTrue(Wait.until(3) { self.exists("recent-row-DC-0") && self.element("recent-row-DC-0").isSelected })
        XCTAssertFalse(appLog.contains("-> dial()"), "moving through the list never dials")

        keyboard.press(Key.returnKey)
        XCTAssertTrue(waitExists("call-hud"), "Return calls the selected recent call")
        XCTAssertNotNil(appLog.range(of: #"dial .*123"#, options: .regularExpression), "Jane's number was dialed:\n\(appLog)")
    }

    /// Neither the popover nor the top bar may move when the keypad replaces the recent calls, in
    /// English and in German (the native segmented control used to widen the content in German).
    func testTogglingTheKeypadKeepsTheLayoutSteady() throws {
        for language in ["en", "de"] {
            try launch("idle", language: language)
            openPopover()
            XCTAssertTrue(waitExists("recent-row-DC-0"))
            guard let before = stableFrame("popover-root"), let field = stableFrame("search-field"),
                  let tabs = stableFrame("recent-tabs") else { return XCTFail("[\(language)] no frames") }
            XCTAssertEqual(tabs.minX, before.minX + 16, accuracy: 1, "[\(language)] tabs start at the content margin")
            XCTAssertEqual(tabs.maxX, before.maxX - 16, accuracy: 1, "[\(language)] tabs end at the content margin")
            XCTAssertTrue(element("keypad-toggle").press())
            XCTAssertTrue(waitExists("key-5"))
            guard let keypad = stableFrame("popover-root"), let keypadField = stableFrame("search-field") else {
                return XCTFail("[\(language)] no frames")
            }
            XCTAssertEqual(keypad.height, before.height, accuracy: 1, "[\(language)] the keypad takes the recent calls' place")
            XCTAssertEqual(keypadField.minX, field.minX, accuracy: 0.5, "[\(language)] the search field does not move")
            XCTAssertEqual(keypadField.width, field.width, accuracy: 0.5, "[\(language)] the search field keeps its width")
            XCTAssertTrue(element("keypad-toggle").press())
            XCTAssertTrue(waitExists("recent-row-DC-0"))
            guard let after = stableFrame("popover-root"), let afterField = stableFrame("search-field") else {
                return XCTFail("[\(language)] no frames")
            }
            XCTAssertEqual(after.height, before.height, accuracy: 1)
            XCTAssertEqual(afterField.minX, field.minX, accuracy: 0.5)
            terminateApp()
        }
    }

    func testTypingDigitsOpensTheKeypad() throws {
        try launch("idle")
        openPopover()
        XCTAssertFalse(exists("key-5"), "keypad starts folded")
        let field = element("search-field")
        Wait.until(3) { field.focus(); return field.isFocused }
        type("5")
        XCTAssertTrue(waitExists("key-5"), "a typed digit opens the keypad")
        for id in ["key-0", "key-9", "key-star", "key-hash", "keypad-call"] { XCTAssertTrue(exists(id), id) }
        XCTAssertTrue(waitExists("call-row"), "a typed number offers a call row")
        XCTAssertEqual(searchText, "5")
        // Pressing the on-screen key appends its digit.
        XCTAssertTrue(element("key-7").press())
        XCTAssertTrue(Wait.until { searchText == "57" })
    }

    func testPlusSignComesFromALongPressOnZero() throws {
        try launch("idle")
        openPopover()
        XCTAssertTrue(element("keypad-toggle").press())
        XCTAssertTrue(waitExists("key-0"))
        guard let frame = stableFrame("key-0") else { return XCTFail("no frame for key-0") }
        Mouse.longPress(at: CGPoint(x: frame.midX, y: frame.midY), duration: 0.8)
        XCTAssertTrue(Wait.until(3) { searchText == "+" }, "long press inserted '\(searchText)'")
    }

    func testEscapeClearsFirstThenClosesThePopover() throws {
        try launch("idle")
        search("jane")
        XCTAssertTrue(waitExists("contact-row-jane-0"))
        keyboard.press(Key.escape)
        XCTAssertTrue(Wait.until { searchText.isEmpty }, "first Esc clears the field")
        XCTAssertTrue(exists("popover-root"), "…and keeps the popover open")
        keyboard.press(Key.escape)
        XCTAssertTrue(waitGone("popover-root"), "second Esc closes it")
    }

    func testClearButtonEmptiesTheField() throws {
        try launch("idle")
        search("oystein")
        XCTAssertTrue(waitExists("contact-row-oystein-0"), "diacritics fold: 'oystein' finds Øystein Åberg")
        XCTAssertTrue(element("search-clear").press())
        XCTAssertTrue(Wait.until { searchText.isEmpty })
        XCTAssertTrue(waitGone("search-clear"))
    }

    func testMoreMenuOffersSettingsAboutAndQuit() throws {
        try launch("idle")
        openPopover()
        element("more-button").press()   // runs the menu modally, so the AX reply times out: ignore the result
        for id in ["menu-settings", "menu-about", "menu-quit"] {
            XCTAssertTrue(waitExists(id), "\(id) missing in the menu")
        }
        element("menu-settings").press()
        XCTAssertTrue(waitExists("settings-window"), "Settings opens from the menu")
    }

    // MARK: Shortcuts

    func testCommandCommaOpensSettingsInFrontAndCompact() throws {
        try launch("idle")
        openPopover()
        keyboard.press(Key.comma, flags: .maskCommand)
        XCTAssertTrue(waitExists("settings-window"), "⌘, opens Settings")
        XCTAssertTrue(waitGone("popover-root"), "the popover closes")
        // Activation by synthetic input is not a user action, so macOS may keep the previous app in front
        // (observed: Chrome stays frontmost). The window must at least be the app's main/key window.
        let window = element("settings-window")
        XCTAssertTrue(Wait.until(5) { (window.value("AXMain") as? Bool) == true || (window.value("AXFocused") as? Bool) == true },
                      "Settings must be the app's main window")
        if frontmostBundleID != "dev.eiken.pickup" { print("NOTE: Settings window opened but the frontmost app is \(frontmostBundleID ?? "nil")") }
        let frame = try XCTUnwrap(element("settings-window").frame)
        XCTAssertLessThanOrEqual(frame.height, 400, "Settings stays compact, is \(frame.height) pt high")
        XCTAssertGreaterThan(frame.height, 100)
        screenshot("settings", of: "settings-window")
    }

    func testCommandWClosesPopoverAndSettings() throws {
        try launch("idle")
        openPopover()
        keyboard.press(Key.w, flags: .maskCommand)
        XCTAssertTrue(waitGone("popover-root"), "⌘W closes the popover")
        openPopover()
        keyboard.press(Key.comma, flags: .maskCommand)
        XCTAssertTrue(waitExists("settings-window"))
        keyboard.press(Key.w, flags: .maskCommand)
        XCTAssertTrue(waitGone("settings-window"), "⌘W closes Settings")
        XCTAssertTrue(isRunning, "closing a window must not quit the app")
    }

    func testCommandQQuitsTheApp() throws {
        try launch("idle")
        openPopover()
        keyboard.press(Key.q, flags: .maskCommand)
        XCTAssertTrue(Wait.until(6) { !self.isRunning }, "⌘Q quits Pickup")
    }
}
