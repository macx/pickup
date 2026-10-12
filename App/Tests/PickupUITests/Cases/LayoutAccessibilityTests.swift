import XCTest

/// Settings, accessibility labels, keyboard operation, German layouts and appearance variants.
@MainActor
final class LayoutAccessibilityTests: PickupUITestCase {
    private func openSettings() {
        openPopover()
        keyboard.press(Key.comma, flags: .maskCommand)
        XCTAssertTrue(waitExists("settings-window"), "Settings did not open")
        XCTAssertTrue(waitGone("popover-root"))
    }

    private func settingsIdentifiers() -> [String] {
        guard let window = app.find("settings-window") else { return [] }
        return window.all { $0.identifier.hasPrefix("settings-") && $0.identifier != "settings-window" }.map(\.identifier)
    }

    // MARK: Settings

    func testSettingsAreCompactLabelledAndLaidOutCleanlyInBothLanguages() throws {
        for language in ["en", "de"] {
            try launch("idle", language: language)
            openSettings()
            let window = element("settings-window")
            let frame = try XCTUnwrap(stableFrame("settings-window"), "[\(language)] no window frame")
            XCTAssertLessThanOrEqual(frame.height, 385, "[\(language)] Settings is \(frame.height) pt high")
            let ids = Array(Set(settingsIdentifiers())).sorted()
            XCTAssertGreaterThanOrEqual(ids.count, 4, "[\(language)] only found \(ids)")
            assertControlsHaveLabels(in: window)
            // Controls stay inside the window and do not overlap (German strings are longer).
            let controls = ids.filter { !$0.hasPrefix("settings-shortcut-clear") }
            assertLayout(container: "settings-window", children: controls)
            XCTAssertFalse(window.title.isEmpty, "window has a title")
            XCTAssertEqual(window.title, s("Settings", "Einstellungen"), "window title follows the language")
            screenshot("settings", of: "settings-window")
            terminateApp()
        }
    }

    func testSettingsOpenAndCloseWithTheKeyboardOnly() throws {
        // Tab only reaches text fields unless "Full Keyboard Access" is on, so focus traversal is not asserted.
        try launch("idle")
        openSettings()
        keyboard.press(Key.tab)
        XCTAssertTrue(isRunning)
        XCTAssertTrue(exists("settings-window"))
        keyboard.press(Key.w, flags: .maskCommand)
        XCTAssertTrue(waitGone("settings-window"), "⌘W closes Settings from the keyboard")
    }

    // MARK: Accessibility

    func testPopoverExposesLabelsRolesAndIdentifiers() throws {
        try launch("idle")
        search("5")                                   // opens the keypad and a call row
        XCTAssertTrue(waitExists("key-5"))
        let root = element("popover-root")
        assertControlsHaveLabels(in: root)
        let expectedRoles = ["search-field": "AXTextField", "more-button": "AXButton", "keypad-toggle": "AXCheckBox"]
        for (id, role) in expectedRoles { XCTAssertEqual(element(id).role, role, id) }
        for id in ["key-0", "key-1", "key-2", "key-3", "key-4", "key-5", "key-6", "key-7", "key-8", "key-9", "key-star", "key-hash", "keypad-call"] {
            let key = element(id)
            XCTAssertEqual(key.role, "AXButton", id)
            XCTAssertFalse(key.allText.isEmpty, "\(id) has a label")
        }
        XCTAssertTrue(element("keypad-toggle").allText.contains(s("Keypad", "Tastenfeld")))
        XCTAssertTrue(element("more-button").allText.contains(s("More", "Mehr")))
    }

    func testBannerAndHUDExposeLabelledControls() throws {
        try launch("incoming-accept")
        XCTAssertTrue(waitExists("incoming-banner", timeout: 10))
        assertControlsHaveLabels(in: element("incoming-banner"))
        XCTAssertTrue(element("banner-accept").allText.contains(s("Accept", "Annehmen")), element("banner-accept").allText)
        XCTAssertTrue(element("banner-decline").allText.contains(s("Decline", "Ablehnen")), element("banner-decline").allText)
        element("banner-accept").press()
        XCTAssertTrue(waitExists("call-hud"))
        assertControlsHaveLabels(in: element("call-hud"))
        XCTAssertTrue(element("hud-hangup").allText.contains(s("End Call", "Auflegen")), element("hud-hangup").allText)
    }

    // MARK: German layout

    func testGermanBannerAndHUDDoNotOverlapOrOverflow() throws {
        try launch("incoming-accept", language: "de")
        XCTAssertTrue(waitExists("incoming-banner", timeout: 10))
        _ = stableFrame("incoming-banner")
        assertLayout(container: "incoming-banner", children: ["banner-caller", "banner-accept", "banner-decline"])
        screenshot("banner", of: "incoming-banner")
        element("banner-accept").press()
        XCTAssertTrue(waitExists("hud-timer"))
        _ = stableFrame("call-hud")
        assertLayout(container: "call-hud", children: ["hud-caller", "hud-hangup"])
        advance()
        XCTAssertTrue(waitText("hud-state") { $0 == "Anruf beendet" }, hudState())
        _ = stableFrame("call-hud")
        assertLayout(container: "call-hud", children: ["hud-caller", "hud-close"])
    }

    func testVeryLongGermanNameStaysInsideTheRowTheHUDAndTheBanner() throws {
        try launch("outgoing-answered", language: "de")
        search("prof")
        XCTAssertTrue(waitExists("contact-row-long-0"))
        _ = stableFrame("contact-row-long-0")
        assertLayout(container: "popover-root", children: ["contact-row-long-0"])
        let row = element("contact-row-long-0")
        XCTAssertTrue(row.allText.contains("Hohenlohe"), "row exposes the full name to VoiceOver: \(row.allText)")
        keyboard.press(Key.returnKey)
        XCTAssertTrue(waitExists("call-hud"))
        _ = stableFrame("call-hud")
        assertLayout(container: "call-hud", children: ["hud-caller", "hud-hangup"])
        let hud = try XCTUnwrap(app.find("call-hud")?.frame)
        XCTAssertLessThanOrEqual(hud.width, 420, "HUD does not grow with the name")
        XCTAssertTrue(element("hud-caller").allText.contains("Hohenlohe"))
    }

    // MARK: Appearance variants (small fixed matrix)

    func testPopoverInEnglishLightAndGermanDark() throws {
        for (language, style) in [("en", "Light"), ("de", "Dark")] {
            try launch("idle", language: language, extra: ["-AppleInterfaceStyle", style])
            search("max")
            XCTAssertTrue(waitExists("contact-row-multi-2"), "[\(language)/\(style)] rows missing")
            _ = stableFrame("popover-root")
            assertLayout(container: "popover-root", children: ["contact-row-multi-0", "contact-row-multi-1", "contact-row-multi-2"].map { $0 })
            XCTAssertTrue(element("more-button").allText.contains(s("More", "Mehr")))
            screenshot("popover-\(style.lowercased())", of: "popover-root")
            terminateApp()
        }
    }

    func testOnlyInventedContactsAreOffered() throws {
        try launch("idle")
        search("a")
        let rows = app.all { $0.identifier.hasPrefix("contact-row-") }.map(\.identifier)
        XCTAssertFalse(rows.isEmpty)
        let allowed = ["jane", "john", "long", "multi", "oystein"]
        for id in rows { XCTAssertTrue(allowed.contains { id.hasPrefix("contact-row-\($0)-") }, "unexpected row \(id)") }
    }
}
