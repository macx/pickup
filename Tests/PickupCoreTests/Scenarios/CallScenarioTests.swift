import XCTest
@testable import PickupCore

/// Complete calls played through `CallEngine` by a scripted phone, named by user story.
/// Every scenario runs for a transport without audio and one with audio (setting off and on):
/// remote control must behave identically.
@MainActor
final class CallScenarioTests: XCTestCase {
    /// (supportsAudio, takeCallsOnMac)
    private let modes: [(Bool, Bool)] = [(false, false), (true, false), (true, true)]

    private func forEachMode(_ body: (ScriptedPhone, String) throws -> Void) throws {
        for (audio, take) in modes {
            let phone = ScriptedPhone(supportsAudio: audio, takeCallsOnMac: take)
            try body(phone, "supportsAudio=\(audio) takeCallsOnMac=\(take)")
        }
    }

    // MARK: Incoming

    func testIncomingCallIsAcceptedOnTheMacAndEndedByTheCaller() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming()
            XCTAssertEqual(phone.engine.phase, .ringing, mode)
            phone.answerCallList()
            XCTAssertEqual(phone.engine.call?.callerID, .number(ScriptedPhone.jane), mode)

            try phone.engine.accept()
            phone.advance(0.2)
            let answeredAt = phone.scheduler.now
            phone.answered()
            phone.advance(65)
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.engine.call?.duration(at: phone.scheduler.now) ?? 0, 65, accuracy: 0.001, mode)

            phone.remoteHangsUp()
            XCTAssertEqual(phone.engine.phase, .ended, mode)
            XCTAssertEqual(phone.engine.call?.endReason, .remoteEnded, mode)
            XCTAssertEqual(phone.engine.call?.connectedAt, answeredAt, mode)
            XCTAssertEqual(phone.engine.call?.duration(at: phone.scheduler.now.addingTimeInterval(500)) ?? 0, 65, accuracy: 0.001,
                           "duration is frozen once the call ended: \(mode)")
            XCTAssertEqual(phone.userCommands, [.requestCurrentCalls, .acceptCallOnPhone], mode)

            phone.settle()
            XCTAssertEqual(phone.engine.phase, .idle, mode)
            XCTAssertNil(phone.engine.call, mode)
            XCTAssertEqual(phone.finished.count, 1, mode)
        }
    }

    func testIncomingCallIsDeclinedOnTheMac() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming()
            phone.answerCallList()
            try phone.engine.decline()
            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.declined], mode)
            XCTAssertNil(phone.finished.first?.connectedAt, mode)
            XCTAssertNil(phone.finished.first?.duration(at: phone.scheduler.now), mode)
            XCTAssertEqual(phone.commands, [.requestCurrentCalls, .endCall], mode)
            XCTAssertEqual(phone.engine.phase, .idle, mode)
        }
    }

    func testIncomingCallNobodyAnswersIsMissed() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(number: ScriptedPhone.john)
            phone.answerCallList()
            phone.advance(25)
            XCTAssertEqual(phone.engine.phase, .ringing, "ringing does not time out on its own: \(mode)")
            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.missed], mode)
            XCTAssertEqual(phone.finished.first?.number, ScriptedPhone.john, mode)
            XCTAssertEqual(phone.commands, [.requestCurrentCalls], mode)
            phone.assertNoSpontaneousCommands()
        }
    }

    func testCallerWhoWithholdsTheNumberIsShownAsWithheldAndCanStillBeAccepted() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(number: nil)
            phone.answerCallList()
            XCTAssertEqual(phone.engine.call?.callerID, .unknown, "first answer may be early: \(mode)")
            phone.advance(1)
            phone.answerCallList()
            phone.advance(1)
            phone.answerCallList()
            XCTAssertEqual(phone.engine.call?.callerID, .withheld, mode)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 3, mode)

            try phone.engine.accept()
            phone.answered()
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.engine.call?.callerID, .withheld, mode)
        }
    }

    func testCallAnsweredOnThePhoneItselfSendsNoAnswerCommand() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming()
            phone.answerCallList()
            phone.answered()
            phone.advance(10)
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.userCommands, [.requestCurrentCalls], mode)
            phone.remoteHangsUp()
            XCTAssertEqual(phone.finished.map(\.endReason), [.remoteEnded], mode)
        }
    }

    func testDuplicateRingSignalsDoNotCreateASecondCall() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming()
            let id = phone.engine.call?.id
            for _ in 0..<5 {
                phone.transport.emit(.ring)
                phone.transport.emit(.callSetup(.incoming)) // indicator re-reported: no change
            }
            XCTAssertEqual(phone.engine.call?.id, id, mode)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 1, mode)
        }
    }

    func testCallerHangsUpWhileRingingIsMissedNotDeclined() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming()
            phone.answerCallList()
            phone.setupEnded()
            phone.advance(phone.engine.configuration.setupEndGrace + 0.1)
            XCTAssertThrowsError(try phone.engine.decline(), mode) { XCTAssertEqual($0 as? CallEngineError, .invalidPhase(.ended)) }
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.missed], mode)
        }
    }

    // MARK: Outgoing

    func testOutgoingCallIsAnsweredAndHungUpOnTheMac() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber("+49 30 000123")!)
            XCTAssertEqual(phone.engine.phase, .dialing, mode)
            phone.startOutgoing()
            phone.remoteAlerting()
            XCTAssertEqual(phone.engine.call?.isRemoteAlerting, true, mode)
            phone.advance(4)
            phone.answered()
            phone.advance(90)
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.engine.call?.duration(at: phone.scheduler.now) ?? 0, 90, accuracy: 0.001, mode)

            try phone.engine.hangUp()
            phone.remoteHangsUp()
            XCTAssertEqual(phone.engine.call?.endReason, .hungUp, mode)
            XCTAssertEqual(phone.userCommands, [.dial(ScriptedPhone.jane), .endCall], mode)
            phone.settle()
            XCTAssertEqual(phone.engine.phase, .idle, mode)
        }
    }

    func testOutgoingCallTheOtherSideRejectsEndsAsUnanswered() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber(ScriptedPhone.jane)!)
            phone.startOutgoing()
            phone.remoteAlerting()
            phone.transport.emit(.commandCompleted(.other("BUSY"), .callFailure("BUSY")))
            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.unanswered], mode)
            XCTAssertNil(phone.finished.first?.connectedAt, mode)
            XCTAssertEqual(phone.commands, [.dial(ScriptedPhone.jane)], mode)
        }
    }

    func testPhoneRefusesTheDialCommand() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber(ScriptedPhone.jane)!)
            phone.transport.emit(.commandCompleted(.dial, .cmeError(30))) // no network service
            XCTAssertEqual(phone.engine.call?.endReason, .failed, mode)
            XCTAssertEqual(phone.engine.lastCommandFailure?.result, .cmeError(30), mode)
            phone.settle()
            XCTAssertEqual(phone.engine.phase, .idle, mode)
        }
    }

    func testDialingIsCancelledBeforeThePhoneReacts() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber(ScriptedPhone.jane)!)
            try phone.engine.hangUp()
            phone.transport.emit(.commandCompleted(.endCall, .ok))
            phone.startOutgoing() // the phone had already started the call
            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.cancelled], mode)
        }
    }

    func testDialingIsCancelledWhileTheRemoteSideIsAlerting() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber(ScriptedPhone.jane)!)
            phone.startOutgoing()
            phone.remoteAlerting()
            try phone.engine.endCall() // the generic end button
            XCTAssertEqual(phone.commands.last, .endCall, mode)
            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.cancelled], mode)
        }
    }

    func testPhoneNeverStartsTheCallSoTheDialTimesOut() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber(ScriptedPhone.jane)!)
            phone.advance(phone.engine.configuration.dialTimeout - 1)
            XCTAssertEqual(phone.engine.phase, .dialing, mode)
            phone.advance(2)
            XCTAssertEqual(phone.engine.call?.endReason, .failed, mode)
        }
    }

    func testSecondDialWhileDialingIsRefusedAndSendsNothing() throws {
        try forEachMode { phone, mode in
            try phone.engine.dial(DialNumber(ScriptedPhone.jane)!)
            XCTAssertThrowsError(try phone.engine.dial(DialNumber(ScriptedPhone.john)!), mode)
            XCTAssertEqual(phone.commands, [.dial(ScriptedPhone.jane)], mode)
        }
    }

    // MARK: Hold and hang-up

    func testHangUpWhileHeldEndsTheCall() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            phone.transport.emit(.callHeld(.heldOnly))
            XCTAssertEqual(phone.engine.phase, .held, mode)
            try phone.engine.hangUp()
            phone.remoteHangsUp()
            XCTAssertEqual(phone.finished.map(\.endReason), [.hungUp], mode)
        }
    }

    func testHangUpWithNothingGoingOnIsAnErrorAndSendsNothing() throws {
        try forEachMode { phone, mode in
            XCTAssertThrowsError(try phone.engine.hangUp(), mode)
            XCTAssertThrowsError(try phone.engine.decline(), mode)
            XCTAssertThrowsError(try phone.engine.accept(), mode)
            XCTAssertThrowsError(try phone.engine.sendDTMF(DTMFDigit("1")!), mode)
            XCTAssertTrue(phone.commands.isEmpty, mode)
        }
    }

    // MARK: Call waiting

    func testSecondCallWhileTalkingWaitsAndBecomesRingingWhenTheFirstEnds() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            phone.advance(30)
            phone.transport.emit(.callSetup(.incoming))
            phone.transport.emit(.callWaiting(ScriptedPhone.john))
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.engine.waitingCall?.number, ScriptedPhone.john, mode)

            phone.remoteHangsUp() // first caller leaves, the waiting call keeps ringing
            XCTAssertEqual(phone.finished.map(\.endReason), [.remoteEnded], mode)
            XCTAssertEqual(phone.engine.phase, .ringing, mode)
            XCTAssertEqual(phone.engine.call?.number, ScriptedPhone.john, mode)
            XCTAssertNil(phone.engine.waitingCall, mode)

            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.finished.map(\.endReason), [.remoteEnded, .missed], mode)
            XCTAssertEqual(phone.engine.phase, .idle, mode)
            phone.assertNoSpontaneousCommands()
        }
    }

    func testWaitingCallThatStopsRingingLeavesTheActiveCallAlone() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            let id = phone.engine.call?.id
            phone.transport.emit(.callSetup(.incoming))
            phone.setupEnded()
            XCTAssertNil(phone.engine.waitingCall, mode)
            XCTAssertEqual(phone.engine.call?.id, id, mode)
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertTrue(phone.finished.isEmpty, mode)
        }
    }

    // MARK: Link loss, sleep and wake

    func testLinkDropsDuringACallAndComesBackWithinTwoMinutes() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            phone.advance(20)
            let original = phone.engine.call!

            phone.dropLink()
            XCTAssertEqual(phone.engine.call?.endReason, .connectionLost, mode)
            phone.advance(100)
            phone.transport.bringUp(call: true)

            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.engine.call?.id, original.id, mode)
            XCTAssertEqual(phone.engine.call?.number, ScriptedPhone.jane, mode)
            XCTAssertEqual(phone.engine.call?.duration(at: phone.scheduler.now) ?? 0, 120, accuracy: 0.001,
                           "duration counts from the original start across the gap: \(mode)")
            XCTAssertNil(phone.engine.call?.endReason, mode)

            phone.advance(300) // the old ended-display timer must not clear the resumed call
            XCTAssertEqual(phone.engine.phase, .active, mode)
            phone.remoteHangsUp()
            XCTAssertEqual(phone.finished.map(\.endReason), [.connectionLost, .remoteEnded], mode)
        }
    }

    func testLinkComesBackJustAfterTheRestoreWindowStartsANewCall() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            let original = phone.engine.call!
            phone.dropLink()
            phone.advance(phone.engine.configuration.lostCallRestoreWindow + 0.5)
            phone.transport.bringUp(call: true)
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertNotEqual(phone.engine.call?.id, original.id, mode)
            XCTAssertEqual(phone.engine.call?.connectedAtIsApproximate, true, mode)
        }
    }

    func testLinkComesBackAtTheEdgeOfTheRestoreWindowStillResumes() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            let original = phone.engine.call!
            phone.dropLink()
            phone.advance(phone.engine.configuration.lostCallRestoreWindow)
            phone.transport.bringUp(call: true)
            XCTAssertEqual(phone.engine.call?.id, original.id, mode)
        }
    }

    func testLinkComesBackAndTheCallIsOverOnThePhone() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            phone.dropLink()
            phone.advance(2)
            phone.transport.bringUp(call: false)
            XCTAssertEqual(phone.engine.call?.endReason, .connectionLost, mode)
            phone.settle()
            XCTAssertEqual(phone.engine.phase, .idle, mode)
        }
    }

    func testLinkDropsWhileRingingIsAConnectionLossNotAMissedCall() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming()
            phone.dropLink()
            XCTAssertEqual(phone.engine.call?.endReason, .connectionLost, mode)
            phone.settle()
            XCTAssertEqual(phone.engine.phase, .idle, mode)
        }
    }

    func testSleepDuringACallAndWakeWithTheCallStillRunning() throws {
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            phone.advance(10)
            let original = phone.engine.call!

            phone.engine.prepareForSleep()
            phone.dropLink() // the transport closes the SLC before sleep
            phone.advance(45)
            phone.engine.systemDidWake()
            phone.transport.bringUp(call: true)

            XCTAssertEqual(phone.engine.call?.id, original.id, mode)
            XCTAssertEqual(phone.engine.phase, .active, mode)
            XCTAssertEqual(phone.commands.filter { $0 == .prepareForSleep }.count, 1, mode)
            XCTAssertEqual(phone.commands.filter { $0 == .resumeAfterSleep }.count, 1, mode)
            phone.assertNoSpontaneousCommands(allowingLifecycle: true)
        }
    }

    func testWakeWithoutALinkDoesNotInventACall() throws {
        try forEachMode { phone, mode in
            phone.engine.prepareForSleep()
            phone.dropLink()
            phone.engine.systemDidWake()
            phone.transport.bringUp()
            XCTAssertEqual(phone.engine.phase, .idle, mode)
            XCTAssertTrue(phone.finished.isEmpty, mode)
        }
    }

    func testCommandsAfterLinkLossAreRefusedAndSendNothing() throws {
        try forEachMode { phone, mode in
            phone.dropLink()
            XCTAssertThrowsError(try phone.engine.dial(DialNumber(ScriptedPhone.jane)!), mode)
            XCTAssertThrowsError(try phone.engine.accept(), mode)
            XCTAssertTrue(phone.commands.isEmpty, mode)
        }
    }

    // MARK: Unexpected audio link

    func testPhoneOpensSCOOnItsOwnInRemoteControlModeAndTheAudioGoesBack() throws {
        for (audio, take) in [(false, false), (true, false)] {
            let phone = ScriptedPhone(supportsAudio: audio, takeCallsOnMac: take)
            phone.ringIncoming(); phone.answerCallList(); phone.answered()
            phone.transport.emit(.audioConnectionChanged(isOpen: true))
            XCTAssertEqual(phone.commands.filter { $0 == .transferAudioToPhone }.count, 1)
            XCTAssertEqual(phone.engine.lastAudioFallback?.reason, .audioOnMacDisabled)
            phone.transport.emit(.audioConnectionChanged(isOpen: true)) // duplicate report while handing back
            XCTAssertEqual(phone.commands.filter { $0 == .transferAudioToPhone }.count, 1, "no hand-back storm")
            phone.transport.emit(.audioConnectionChanged(isOpen: false))
            XCTAssertEqual(phone.engine.audioRoute, .phone)
            XCTAssertEqual(phone.engine.phase, .active, "the call itself is untouched")
        }
    }

    func testSCOOpenedWithoutAnyCallIsHandedBack() throws {
        let phone = ScriptedPhone(supportsAudio: false)
        phone.transport.emit(.audioConnectionChanged(isOpen: true))
        XCTAssertEqual(phone.commands, [.transferAudioToPhone])
        phone.assertNoSpontaneousCommands()
    }

    func testSCOReopenedAfterBeingClosedIsHandedBackAgain() throws {
        let phone = ScriptedPhone(supportsAudio: false)
        for _ in 0..<3 {
            phone.transport.emit(.audioConnectionChanged(isOpen: true))
            phone.transport.emit(.audioConnectionChanged(isOpen: false))
        }
        XCTAssertEqual(phone.commands.filter { $0 == .transferAudioToPhone }.count, 3)
    }

    func testAudioOnMacKeepsSCOWhenEnabledAndFallsBackWhenItDrops() throws {
        let phone = ScriptedPhone(supportsAudio: true, takeCallsOnMac: true)
        phone.ringIncoming(); phone.answerCallList(); phone.answered()
        phone.transport.emit(.audioConnectionChanged(isOpen: true))
        XCTAssertTrue(phone.commands.filter { $0 == .transferAudioToPhone }.isEmpty)
        XCTAssertEqual(phone.engine.audioRoute, .mac)
        phone.advance(60) // watchdog was cancelled by the open SCO
        XCTAssertTrue(phone.commands.filter { $0 == .transferAudioToPhone }.isEmpty)
        phone.transport.emit(.audioConnectionChanged(isOpen: false))
        XCTAssertEqual(phone.engine.lastAudioFallback?.reason, .audioDropped)
        XCTAssertEqual(phone.engine.phase, .active)
    }

    func testAudioDoesNotComeUpInTimeSoTheCallStaysOnThePhone() throws {
        let phone = ScriptedPhone(supportsAudio: true, takeCallsOnMac: true)
        phone.ringIncoming(); phone.answerCallList(); phone.answered()
        phone.advance(phone.engine.configuration.audioSetupTimeout + 0.1)
        XCTAssertEqual(phone.engine.lastAudioFallback?.reason, .audioSetupTimedOut)
        XCTAssertEqual(phone.engine.phase, .active)
    }

    // MARK: AT+CLCC retries

    func testNumberLookupAsksExactlyThreeTimesOneSecondApart() throws {
        try forEachMode { phone, mode in
            phone.callList = []
            phone.transport.emit(.callSetup(.incoming))
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 1, mode)
            phone.answerCallList()
            phone.advance(0.9)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 1, "retry delay is 1 s: \(mode)")
            phone.advance(0.2)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 2, mode)
            phone.answerCallList()
            phone.advance(1)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 3, mode)
            phone.answerCallList()
            phone.advance(60)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 3, mode)
            XCTAssertEqual(phone.engine.call?.callerID, .unknown, "never guessed: \(mode)")
            XCTAssertEqual(phone.engine.phase, .ringing, mode)
        }
    }

    func testNumberLookupSucceedsOnTheSecondTryAndStopsAsking() throws {
        try forEachMode { phone, mode in
            phone.callList = []
            phone.transport.emit(.callSetup(.incoming))
            phone.answerCallList()
            phone.advance(1)
            phone.callList = [HFPCall(index: 1, direction: .incoming, status: .incoming, number: ScriptedPhone.john)]
            phone.answerCallList()
            phone.advance(60)
            XCTAssertEqual(phone.engine.call?.number, ScriptedPhone.john, mode)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 2, mode)
        }
    }

    func testNumberLookupErrorsAreRetriedAndTheCallStaysUsable() throws {
        try forEachMode { phone, mode in
            phone.transport.emit(.callSetup(.incoming))
            phone.transport.emit(.commandCompleted(.currentCalls, .error))
            phone.advance(1)
            phone.transport.emit(.commandCompleted(.currentCalls, .cmeError(30)))
            phone.advance(1)
            phone.transport.emit(.commandCompleted(.currentCalls, .error))
            phone.advance(30)
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 3, mode)
            try phone.engine.accept()
            XCTAssertEqual(phone.commands.last, .acceptCallOnPhone, mode)
        }
    }

    func testLookupRetryIsCancelledWhenTheCallEnds() throws {
        try forEachMode { phone, mode in
            phone.transport.emit(.callSetup(.incoming))
            phone.answerCallList()
            phone.setupEnded()
            phone.settle()
            XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 1, mode)
        }
    }

    func testCallStartedWhileTheLinkIsStillComingUpLooksUpTheNumberOnConnect() throws {
        let phone = ScriptedPhone(supportsAudio: false)
        phone.dropLink()
        phone.transport.clearCommands()
        phone.transport.bringUp(callSetup: .incoming)
        XCTAssertEqual(phone.engine.phase, .ringing)
        XCTAssertEqual(phone.commands.filter { $0 == .requestCurrentCalls }.count, 1)
    }

    // MARK: Nothing is ever started without a command

    func testNoScenarioEverSendsDialAcceptOrHangUpByItself() throws {
        // Every passive scenario above, run back to back through one engine.
        try forEachMode { phone, mode in
            phone.ringIncoming(); phone.answerCallList(); phone.answered(); phone.advance(5)
            phone.transport.emit(.callHeld(.heldOnly)); phone.transport.emit(.callHeld(.none))
            phone.transport.emit(.callSetup(.incoming)); phone.transport.emit(.callWaiting(ScriptedPhone.john))
            phone.remoteHangsUp(); phone.setupEnded(); phone.settle()
            phone.dropLink(); phone.transport.bringUp(call: true)
            phone.transport.emit(.audioConnectionChanged(isOpen: true))
            phone.transport.emit(.audioConnectionChanged(isOpen: false))
            phone.transport.emit(.call(false)); phone.settle()
            phone.assertNoSpontaneousCommands()
            XCTAssertFalse(phone.commands.contains { if case .dial = $0 { return true } else { return false } }, mode)
        }
    }

    func testServiceCodeFromALinkNeverReachesThePhoneWithoutConfirmation() throws {
        try forEachMode { phone, mode in
            for text in ["tel:**21*0300000123%23", "tel:*%2367%23", "callto:%2321%23", "tel:*31%23+4930000123"] {
                if let number = DialNumber(url: URL(string: text)!) {
                    XCTAssertThrowsError(try phone.engine.dial(number), "\(text) \(mode)")
                }
            }
            XCTAssertTrue(phone.commands.isEmpty, mode)
            XCTAssertEqual(phone.engine.phase, .idle, mode)
        }
    }
}
