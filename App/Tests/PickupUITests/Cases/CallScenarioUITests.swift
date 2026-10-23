import XCTest

/// The scripted phone plays complete calls; the tests drive banner and HUD like a user.
@MainActor
final class CallScenarioUITests: PickupUITestCase {
    private var unknownCaller: String { s("Unknown caller", "Unbekannter Anrufer") }
    private var callEnded: String { s("Call ended", "Anruf beendet") }

    /// Waits for the banner and checks the caller. The banner must not take keyboard focus.
    private func waitForBanner(caller: String = "Jane Doe", file: StaticString = #filePath, line: UInt = #line) {
        let before = frontmostBundleID
        XCTAssertTrue(waitExists("incoming-banner", timeout: 10), "no incoming banner", file: file, line: line)
        XCTAssertTrue(element("banner-caller").allText.contains(caller), "banner shows '\(element("banner-caller").allText)'", file: file, line: line)
        XCTAssertNotEqual(frontmostBundleID, "dev.eiken.pickup", "the banner must not activate Pickup (front: \(frontmostBundleID ?? "nil"), before: \(before ?? "nil"))", file: file, line: line)
        XCTAssertFalse(app.value("AXFocusedUIElement").map { AXElement(ref: $0 as! AXUIElement).identifier.hasPrefix("banner") } ?? false,
                       "no banner control has keyboard focus", file: file, line: line)
    }

    /// The timer exposes the label "Call duration" and a spoken elapsed-time value that keeps changing.
    private func assertTimerRuns(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitExists("hud-timer"), "no call timer", file: file, line: line)
        let timer = element("hud-timer")
        XCTAssertTrue(timer.allText.contains(s("Call duration", "Anrufdauer")), "timer text \(timer.allText)", file: file, line: line)
        XCTAssertTrue(Wait.until { !self.element("hud-timer").stringValue.isEmpty }, "timer has no accessibility value", file: file, line: line)
        let first = element("hud-timer").stringValue
        XCTAssertTrue(Wait.until(5) { self.element("hud-timer").stringValue != first }, "timer value stays '\(first)'", file: file, line: line)
    }

    private func assertEnded(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitText("hud-state") { $0 == text }, "ended state is '\(hudState())', expected '\(text)'", file: file, line: line)
        XCTAssertTrue(exists("hud-close"), "ended HUD offers Close", file: file, line: line)
        XCTAssertFalse(exists("hud-hangup"), file: file, line: line)
    }

    // MARK: Incoming

    func testIncomingCallIsAcceptedTimedAndEndedByTheCaller() throws {
        try launch("incoming-accept")
        waitForBanner()
        screenshot("banner", of: "incoming-banner")
        XCTAssertTrue(element("banner-accept").press())
        XCTAssertTrue(waitGone("incoming-banner"))
        XCTAssertTrue(waitExists("call-hud"))
        XCTAssertTrue(element("hud-caller").allText.contains("Jane Doe"))
        assertTimerRuns()
        screenshot("hud-active", of: "call-hud")
        advance()                       // caller hangs up
        assertEnded(callEnded)
        XCTAssertTrue(waitGone("call-hud", timeout: 10), "the ended HUD returns to idle")
        XCTAssertTrue(isRunning)
    }

    func testIncomingCallIsDeclined() throws {
        try launch("incoming-decline")
        waitForBanner()
        XCTAssertTrue(element("banner-decline").press())
        XCTAssertTrue(waitGone("incoming-banner"))
        XCTAssertFalse(appLog.contains("-> acceptCallOnPhone"), "decline must not accept")
        XCTAssertTrue(Wait.until(4) { self.appLog.contains("decline") || self.appLog.contains("endCall") }, "no decline in the log:\n\(appLog)")
        // The decline is shown briefly (or not at all) and the UI returns to idle.
        XCTAssertTrue(waitGone("call-hud", timeout: 10))
    }

    func testIncomingCallStopsRingingAndIsMissed() throws {
        try launch("incoming-missed")
        waitForBanner()
        advance()                       // the phone stops ringing
        XCTAssertTrue(waitGone("incoming-banner", timeout: 10), "banner stays after the caller gave up")
        XCTAssertTrue(waitGone("call-hud", timeout: 10))
        XCTAssertFalse(appLog.contains("-> acceptCallOnPhone"))
        XCTAssertTrue(isRunning)
    }

    func testCallerWithheldIsShownAsUnknownAndCanBeAccepted() throws {
        try launch("incoming-withheld")
        XCTAssertTrue(waitExists("incoming-banner", timeout: 10))
        XCTAssertTrue(waitText("banner-caller") { $0.contains(self.unknownCaller) }, "banner shows '\(element("banner-caller").allText)'")
        XCTAssertTrue(element("banner-accept").press())
        XCTAssertTrue(waitExists("call-hud"))
        XCTAssertTrue(waitText("hud-caller") { $0.contains(self.unknownCaller) })
        advance()
        assertEnded(callEnded)
    }

    func testEndingAnActiveCallWithTheHangUpButton() throws {
        try launch("incoming-accept")
        waitForBanner()
        XCTAssertTrue(element("banner-accept").press())
        XCTAssertTrue(waitExists("hud-timer"))
        XCTAssertTrue(element("hud-hangup").press())
        // Hung up on the Mac: no "ended" state, the HUD closes once the phone confirms.
        XCTAssertFalse(exists("hud-close"), "a call ended on the Mac shows no ended state")
        XCTAssertTrue(waitGone("call-hud", timeout: 5), "the HUD closes after hanging up")
    }

    /// A call accepted in Pickup keeps the keyboard focus in Pickup: End Call has focus, so Return can end
    /// the call. During the call the status item focuses the HUD instead of opening the popover.
    ///
    /// Return and Esc themselves are not tested here: key events posted to the process do not reach the
    /// non-activating call panel while Pickup is not the active app (real key presses do). They are part
    /// of the manual hardware check.
    func testAcceptedCallKeepsFocusOnEndCall() throws {
        try launch("incoming-accept")
        waitForBanner()
        XCTAssertTrue(element("banner-accept").press())
        XCTAssertTrue(waitExists("hud-timer"))
        XCTAssertTrue(Wait.until(3) { self.element("hud-hangup").isFocused }, "End Call has focus after accepting in Pickup")
        XCTAssertTrue(element("status-item").press())
        XCTAssertTrue(Wait.until(3) { self.element("hud-hangup").isFocused }, "the status item keeps End Call focused")
        XCTAssertFalse(exists("popover-root"), "the popover must not open during a call")
        screenshot("hud-focused", of: "call-hud")
        XCTAssertTrue(element("hud-hangup").press())
        // Hung up on the Mac: the HUD closes without an ended state.
        XCTAssertTrue(waitGone("call-hud", timeout: 5), "the HUD did not close after hanging up")
    }

    // MARK: Outgoing

    func testOutgoingCallIsDialedRingsAnswersAndEnds() throws {
        try launch("outgoing-answered")
        dialWithKeyboard("jane")
        XCTAssertTrue(waitText("hud-state") { $0 == self.s("Calling…", "Anruf läuft …") }, "state '\(hudState())'")
        XCTAssertTrue(element("hud-caller").allText.contains("Jane Doe"))
        XCTAssertTrue(Wait.until(3) { self.element("hud-hangup").isFocused }, "a call placed from Pickup focuses End Call (Return ends it)")
        advance()                       // remote side alerting
        XCTAssertTrue(waitText("hud-state") { $0 == self.s("Ringing…", "Es klingelt…") }, "state '\(hudState())'")
        advance()                       // answered
        assertTimerRuns()
        advance()                       // remote hangs up
        assertEnded(callEnded)
    }

    func testOutgoingCallToABusyNumberEndsWithoutAnswer() throws {
        try launch("outgoing-busy")
        dialWithKeyboard("john")
        advance()                       // remote side alerting
        XCTAssertTrue(waitText("hud-state") { $0 == self.s("Ringing…", "Es klingelt…") })
        advance()                       // the phone reports BUSY
        XCTAssertTrue(waitExists("hud-close", timeout: 10), "busy call must end; state '\(hudState())'")
        let state = hudState()
        XCTAssertFalse(state.isEmpty, "ended HUD explains why")
        XCTAssertNotEqual(state, s("Calling…", "Anruf läuft …"))
        XCTAssertNotEqual(state, callEnded, "a busy number is not a normal ended call (got '\(state)')")
    }

    func testOutgoingCallIsCancelledWhileRinging() throws {
        try launch("outgoing-cancel")
        dialWithKeyboard("jane")
        advance()                       // alerting
        XCTAssertTrue(waitText("hud-state") { $0 == self.s("Ringing…", "Es klingelt…") })
        XCTAssertTrue(element("hud-hangup").press())
        XCTAssertFalse(exists("hud-close"), "a call cancelled on the Mac shows no ended state")
        XCTAssertTrue(waitGone("call-hud", timeout: 10))
    }

    func testCancelDuringDialingBeforeTheRemoteSideAlerts() throws {
        try launch("outgoing-cancel")
        dialWithKeyboard("jane")
        XCTAssertTrue(element("hud-hangup").press())
        XCTAssertFalse(exists("hud-close"), "cancelled during dialing shows no ended state")
        XCTAssertTrue(waitGone("call-hud", timeout: 10))
    }

    // MARK: Waiting and link loss

    func testCallWaitingShowsTheSecondCallerAndPromotesItWhenTheFirstEnds() throws {
        try launch("call-waiting")
        waitForBanner()
        XCTAssertTrue(element("banner-accept").press())
        XCTAssertTrue(waitExists("hud-timer"))
        XCTAssertTrue(element("hud-caller").allText.contains("Jane Doe"))
        advance()                       // John Roe is waiting
        let waiting = s("Call waiting: John Roe", "Anruf wartet: John Roe")
        XCTAssertTrue(Wait.until(8) { self.app.first { $0.role == "AXStaticText" && $0.allText.contains(waiting) } != nil },
                      "no '\(waiting)' text in the HUD")
        XCTAssertTrue(exists("hud-hangup"), "the active call stays controllable")
        XCTAssertFalse(exists("incoming-banner"), "a waiting call is shown in the HUD, not as a banner")
        advance()                       // Jane hangs up: her HUD ends, John's call rings
        XCTAssertTrue(waitExists("incoming-banner", timeout: 10), "the waiting call must surface as a banner")
        XCTAssertTrue(waitText("banner-caller") { $0.contains("John Roe") }, "banner shows '\(element("banner-caller").allText)'")
        XCTAssertTrue(element("banner-decline").press())
        XCTAssertTrue(waitGone("incoming-banner"))
    }

    func testLinkLossEndsTheCallAndTheCallResumesWhenTheLinkReturns() throws {
        try launch("link-loss-resume")
        waitForBanner()
        XCTAssertTrue(element("banner-accept").press())
        XCTAssertTrue(waitExists("hud-timer"))
        advance()                       // link drops
        XCTAssertTrue(waitText("hud-state") { $0 == self.s("Connection to phone lost", "Verbindung zum Telefon verloren") },
                      "state '\(hudState())'")
        advance()                       // link returns while the call still runs on the phone
        XCTAssertTrue(waitExists("hud-timer", timeout: 10), "the call is not resumed after the link came back; state '\(hudState())'")
        advance()
        assertEnded(callEnded)
    }

    func testCallCycleStressSurvives() throws {
        let result = URL(fileURLWithPath: NSTemporaryDirectory() + "callcycle.txt")
        try? FileManager.default.removeItem(at: result)
        try launch("stress-cycle")
        // 20 cycles of the in-app self test; the app must stay alive and responsive, the panels keep one corner.
        XCTAssertTrue(Wait.until(60) { FileManager.default.fileExists(atPath: result.path) || !self.isRunning }, "stress test did not finish")
        XCTAssertTrue(isRunning, "Pickup crashed during the call cycle")
        let verdict = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
        XCTAssertTrue(verdict.hasPrefix("OK"), "self test verdict: \(verdict)")
        XCTAssertNotNil(app.find("status-item"), "the app stopped answering accessibility requests")
        openPopover()
    }
}
