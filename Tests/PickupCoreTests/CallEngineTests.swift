import XCTest
@testable import PickupCore

@MainActor
final class CallEngineTests: XCTestCase {
    private var transport: MockHFPTransport!
    private var scheduler: ManualScheduler!
    private var engine: CallEngine!
    private var finished: [CallInfo] = []

    override func setUp() async throws {
        transport = MockHFPTransport()
        scheduler = ManualScheduler()
        engine = CallEngine(transport: transport, scheduler: scheduler)
        finished = []
        engine.onCallFinished = { [unowned self] in self.finished.append($0) }
        transport.bringUp()
        transport.clearCommands()
    }

    private func incomingEntry(_ number: String? = "+4930000123", status: CallListStatus = .incoming) -> HFPCall {
        HFPCall(index: 1, direction: .incoming, status: status, number: number, numberType: 145)
    }

    private func ring() {
        transport.emit(.callSetup(.incoming))
    }

    // MARK: Incoming

    func testCallsetupIncomingRingsAndRequestsCallList() {
        ring()
        XCTAssertEqual(engine.phase, .ringing)
        XCTAssertEqual(engine.call?.callerID, .unknown)
        XCTAssertEqual(transport.commands, [.requestCurrentCalls])

        transport.emit(.currentCalls([incomingEntry()]))
        XCTAssertEqual(engine.call?.callerID, .number("+4930000123"))
        XCTAssertEqual(engine.call?.direction, .incoming)
    }

    func testEmptyCallListIsRetriedThenGivenUp() {
        ring()
        transport.emit(.currentCalls([]))
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 2)
        transport.emit(.currentCalls([]))
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 3)
        transport.emit(.currentCalls([]))
        scheduler.advance(by: 5)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 3, "at most numberLookupAttempts requests")
        XCTAssertEqual(engine.call?.callerID, .unknown)
        XCTAssertEqual(engine.phase, .ringing)
    }

    func testFailedCallListIsRetried() {
        ring()
        transport.emit(.commandCompleted(.currentCalls, .error))
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 2)
    }

    func testWithheldNumberOnlyAfterRetries() {
        ring()
        transport.emit(.currentCalls([incomingEntry(nil)]))
        XCTAssertEqual(engine.call?.callerID, .unknown, "Android may list the call before its number")
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 2)
        transport.emit(.currentCalls([incomingEntry("")]))
        XCTAssertEqual(engine.call?.callerID, .unknown)
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 3)
        transport.emit(.currentCalls([incomingEntry("")]))
        XCTAssertEqual(engine.call?.callerID, .withheld)
    }

    func testNumberArrivingOnRetryAfterEmptyEntry() {
        ring()
        transport.emit(.currentCalls([incomingEntry("")]))
        scheduler.advance(by: 1)
        transport.emit(.currentCalls([incomingEntry("+4930000123")]))
        XCTAssertEqual(engine.call?.callerID, .number("+4930000123"))
    }

    func testCLIPSetsNumberWithoutCallList() {
        ring()
        transport.emit(.ring)
        transport.emit(.callerID("+4930000123"))
        XCTAssertEqual(engine.call?.number, "+4930000123")
    }

    func testAcceptSendsCommandAndCallBecomesActive() throws {
        ring()
        try engine.accept()
        XCTAssertEqual(transport.commands.last, .acceptCallOnPhone)
        XCTAssertEqual(engine.phase, .ringing, "state follows the phone, not the command")

        scheduler.advance(by: 0.1)
        let answeredAt = scheduler.now
        transport.emit(.call(true))
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 2)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.call?.connectedAt, answeredAt)
        XCTAssertEqual(engine.call?.connectedAtIsApproximate, false)
        XCTAssertEqual(engine.call?.duration(at: scheduler.now) ?? 0, 2, accuracy: 0.001)
    }

    func testCallsetupNoneBeforeCallOneWithinGraceStillAnswers() {
        ring()
        transport.emit(.callSetup(.none)) // some phones send this order
        scheduler.advance(by: 0.2)
        transport.emit(.call(true))
        scheduler.advance(by: 1)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertTrue(finished.isEmpty)
    }

    func testDeclineWhileRinging() throws {
        ring()
        try engine.decline()
        XCTAssertEqual(transport.commands.last, .endCall)
        transport.emit(.commandCompleted(.endCall, .ok))
        transport.emit(.callSetup(.none))
        XCTAssertEqual(engine.phase, .ringing, "grace period first")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(engine.phase, .ended)
        XCTAssertEqual(engine.call?.endReason, .declined)
        XCTAssertEqual(finished.map(\.endReason), [.declined])

        scheduler.advance(by: engine.configuration.endedDisplayDuration)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.call)
    }

    func testMissedCall() {
        ring()
        scheduler.advance(by: 20)
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 0.5)
        XCTAssertEqual(engine.call?.endReason, .missed)
        XCTAssertEqual(finished.count, 1)
    }

    func testRejectedEndCallDoesNotTurnAMissedCallIntoDeclined() throws {
        ring()
        try engine.decline()
        transport.emit(.commandCompleted(.endCall, .error))
        XCTAssertEqual(engine.lastCommandFailure?.command, .endCall)
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 0.5)
        XCTAssertEqual(engine.call?.endReason, .missed)
    }

    func testNewCallDuringEndedDisplayReplacesIt() {
        ring()
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 1)
        XCTAssertEqual(engine.phase, .ended)
        let firstID = engine.call?.id
        ring()
        XCTAssertEqual(engine.phase, .ringing)
        XCTAssertNotEqual(engine.call?.id, firstID)
        scheduler.advance(by: 10)
        XCTAssertEqual(engine.phase, .ringing, "the old clear timer must not clear the new call")
    }

    // MARK: Active / held

    private func makeActive() {
        ring()
        transport.emit(.currentCalls([incomingEntry()]))
        transport.emit(.call(true))
        transport.emit(.callSetup(.none))
        transport.clearCommands()
    }

    func testHoldAndResume() {
        makeActive()
        transport.emit(.callHeld(.heldOnly))
        XCTAssertEqual(engine.phase, .held)
        transport.emit(.callHeld(.none))
        XCTAssertEqual(engine.phase, .active)
    }

    func testHangUpActiveCall() throws {
        makeActive()
        try engine.hangUp()
        XCTAssertEqual(transport.commands, [.endCall])
        transport.emit(.call(false))
        XCTAssertEqual(engine.call?.endReason, .hungUp)
    }

    func testRemoteEndsHeldCall() {
        makeActive()
        transport.emit(.callHeld(.heldOnly))
        transport.emit(.callHeld(.none))
        transport.emit(.call(false))
        XCTAssertEqual(engine.call?.endReason, .remoteEnded)
    }

    func testDTMFOnlyWhileActive() throws {
        ring()
        XCTAssertThrowsError(try engine.sendDTMF(DTMFDigit("5")!)) { error in
            XCTAssertEqual(error as? CallEngineError, .invalidPhase(.ringing))
        }
        transport.emit(.call(true))
        try engine.sendDTMF(DTMFDigit("5")!)
        XCTAssertEqual(transport.commands.last, .sendDTMF("5"))
    }

    func testCallWaitingDoesNotDisturbActiveCall() {
        makeActive()
        let activeID = engine.call?.id
        transport.emit(.callSetup(.incoming))
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.call?.id, activeID)
        XCTAssertNotNil(engine.waitingCall)
        XCTAssertEqual(transport.commands, [.requestCurrentCalls])

        transport.emit(.currentCalls([
            HFPCall(index: 1, direction: .incoming, status: .active, number: "+4930000123"),
            HFPCall(index: 2, direction: .incoming, status: .waiting, number: "+4940000456"),
        ]))
        XCTAssertEqual(engine.waitingCall?.number, "+4940000456")
        XCTAssertEqual(engine.call?.number, "+4930000123")

        transport.emit(.callSetup(.none))
        XCTAssertNil(engine.waitingCall)
        XCTAssertEqual(engine.phase, .active)
    }

    func testWaitingCallKeepsRingingWhenActiveCallEnds() {
        makeActive()
        transport.emit(.callSetup(.incoming))
        transport.emit(.callWaiting("+4940000456"))
        transport.emit(.call(false))
        XCTAssertEqual(finished.last?.endReason, .remoteEnded)
        XCTAssertEqual(engine.phase, .ringing)
        XCTAssertEqual(engine.call?.number, "+4940000456")
    }

    // MARK: Outgoing

    func testDialFlow() throws {
        try engine.dial(DialNumber("+49 30 000-123")!)
        XCTAssertEqual(transport.commands, [.dial("+4930000123")])
        XCTAssertEqual(engine.phase, .dialing)
        XCTAssertEqual(engine.call?.direction, .outgoing)
        XCTAssertEqual(engine.call?.number, "+4930000123")

        transport.emit(.commandCompleted(.dial, .ok))
        transport.emit(.callSetup(.outgoing))
        XCTAssertEqual(engine.call?.isRemoteAlerting, false)
        transport.emit(.callSetup(.remoteAlerting))
        XCTAssertEqual(engine.call?.isRemoteAlerting, true)
        scheduler.advance(by: 30) // dial timeout must be cancelled by the phone's confirmation
        XCTAssertEqual(engine.phase, .dialing)

        transport.emit(.call(true))
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 1)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.call?.isRemoteAlerting, false)
        XCTAssertNotNil(engine.call?.connectedAt)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 0, "number already known")
    }

    func testDialRejectedByPhoneFails() throws {
        try engine.dial(DialNumber("+4930000123")!)
        transport.emit(.commandCompleted(.dial, .cmeError(30)))
        XCTAssertEqual(engine.call?.endReason, .failed)
        XCTAssertEqual(engine.lastCommandFailure?.result, .cmeError(30))
    }

    func testDialTimeout() throws {
        try engine.dial(DialNumber("+4930000123")!)
        scheduler.advance(by: engine.configuration.dialTimeout + 0.1)
        XCTAssertEqual(engine.call?.endReason, .failed)
    }

    func testOutgoingCallNotAnswered() throws {
        try engine.dial(DialNumber("+4930000123")!)
        transport.emit(.callSetup(.outgoing))
        transport.emit(.callSetup(.remoteAlerting))
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 0.5)
        XCTAssertEqual(engine.call?.endReason, .unanswered)
    }

    func testCancelOutgoingCall() throws {
        try engine.dial(DialNumber("+4930000123")!)
        transport.emit(.callSetup(.outgoing))
        try engine.hangUp()
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 0.5)
        XCTAssertEqual(engine.call?.endReason, .cancelled)
    }

    func testCallDialedOnThePhoneIsShownAndLookedUp() {
        transport.emit(.callSetup(.outgoing))
        XCTAssertEqual(engine.phase, .dialing)
        XCTAssertEqual(engine.call?.callerID, .unknown)
        transport.emit(.currentCalls([HFPCall(index: 1, direction: .outgoing, status: .dialing, number: "0300000123")]))
        XCTAssertEqual(engine.call?.number, "0300000123")
    }

    func testServiceCodeNeedsExplicitPermission() throws {
        let forwarding = DialNumber(url: URL(string: "tel:**21*0300000123%23")!)!
        XCTAssertThrowsError(try engine.dial(forwarding)) {
            XCTAssertEqual($0 as? CallEngineError, .serviceCodeNeedsConfirmation)
        }
        XCTAssertTrue(transport.commands.isEmpty)
        XCTAssertEqual(engine.phase, .idle)

        try engine.dial(forwarding, allowServiceCode: true) // dial pad / confirmed
        XCTAssertEqual(transport.commands, [.dial("**21*0300000123#")])
    }

    func testCancelSurvivesRejectedHangUpAndEndsTheCallWhenThePhoneStartsIt() throws {
        try engine.dial(DialNumber("+4930000123")!)
        try engine.hangUp() // before the phone confirmed the dial
        transport.emit(.commandCompleted(.endCall, .error))
        transport.emit(.callSetup(.outgoing)) // the phone starts the call anyway
        XCTAssertEqual(transport.count(.endCall), 2, "ended again")
        transport.emit(.callSetup(.remoteAlerting))
        XCTAssertEqual(transport.count(.endCall), 2, "only once")
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 0.5)
        XCTAssertEqual(engine.call?.endReason, .cancelled)
    }

    func testCancelledCallThatGetsAnsweredIsEndedAgain() throws {
        try engine.dial(DialNumber("+4930000123")!)
        try engine.hangUp()
        transport.emit(.commandCompleted(.endCall, .error))
        transport.emit(.call(true))
        XCTAssertEqual(transport.count(.endCall), 2)
        transport.emit(.call(false))
        XCTAssertEqual(engine.call?.endReason, .hungUp)
    }

    func testCancelledUnconfirmedDialTimesOutAsCancelled() throws {
        try engine.dial(DialNumber("+4930000123")!)
        try engine.hangUp()
        transport.emit(.commandCompleted(.endCall, .error))
        scheduler.advance(by: engine.configuration.dialTimeout + 0.1)
        XCTAssertEqual(engine.call?.endReason, .cancelled)
    }

    func testDialWhileCallIsLiveIsRefused() {
        ring()
        XCTAssertThrowsError(try engine.dial(DialNumber("123")!)) { error in
            XCTAssertEqual(error as? CallEngineError, .callInProgress)
        }
    }

    // MARK: Guards

    func testCommandsNeedALink() {
        transport.emit(.linkStateChanged(.disconnected))
        XCTAssertThrowsError(try engine.accept()) { XCTAssertEqual($0 as? CallEngineError, .notConnected) }
        XCTAssertThrowsError(try engine.dial(DialNumber("123")!)) { XCTAssertEqual($0 as? CallEngineError, .notConnected) }
    }

    func testAcceptOnlyWhileRinging() {
        XCTAssertThrowsError(try engine.accept()) { XCTAssertEqual($0 as? CallEngineError, .invalidPhase(.idle)) }
    }

    // MARK: Link loss and reconnect

    func testLinkLossEndsCallAndReconnectResumesIt() {
        makeActive()
        scheduler.advance(by: 30)
        let original = engine.call!

        transport.emit(.linkStateChanged(.disconnected))
        XCTAssertEqual(engine.call?.endReason, .connectionLost)
        XCTAssertEqual(engine.phoneStatus, PhoneStatus())
        transport.emit(.reconnectScheduled(scheduler.now.addingTimeInterval(2)))
        XCTAssertEqual(engine.nextReconnectAttempt, scheduler.now.addingTimeInterval(2))

        scheduler.advance(by: 2)
        transport.bringUp(call: true)
        XCTAssertNil(engine.nextReconnectAttempt)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.call?.id, original.id)
        XCTAssertEqual(engine.call?.connectedAt, original.connectedAt)
        XCTAssertEqual(engine.call?.number, original.number)
        XCTAssertEqual(engine.call?.connectedAtIsApproximate, false)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 1, "refresh after resume")
    }

    func testLinkUpMidCallWithoutHistoryIsApproximate() {
        transport.emit(.linkStateChanged(.disconnected))
        transport.clearCommands()
        transport.bringUp(call: true)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.call?.direction, .unknown)
        XCTAssertEqual(engine.call?.connectedAtIsApproximate, true)
        XCTAssertEqual(transport.count(.requestCurrentCalls), 1)

        transport.emit(.currentCalls([HFPCall(index: 1, direction: .outgoing, status: .active, number: "0300000123")]))
        XCTAssertEqual(engine.call?.direction, .outgoing)
        XCTAssertEqual(engine.call?.number, "0300000123")
    }

    func testStaleLostCallIsNotResumed() {
        makeActive()
        let original = engine.call!
        transport.emit(.linkStateChanged(.disconnected))
        scheduler.advance(by: engine.configuration.lostCallRestoreWindow + 1)
        transport.bringUp(call: true)
        XCTAssertNotEqual(engine.call?.id, original.id)
    }

    func testNewIncomingCallAfterReconnectIsNotTheLostCall() {
        makeActive()
        let original = engine.call!
        transport.emit(.linkStateChanged(.disconnected))
        transport.bringUp()
        ring()
        XCTAssertNotEqual(engine.call?.id, original.id)
        XCTAssertEqual(engine.call?.callerID, .unknown)
    }

    func testCallEventsWhileDisconnectedAreIgnored() {
        transport.emit(.linkStateChanged(.disconnecting))
        transport.emit(.callSetup(.incoming))
        transport.emit(.ring)
        transport.emit(.currentCalls([incomingEntry()]))
        XCTAssertEqual(engine.phase, .idle)
        transport.emit(.linkStateChanged(.disconnected))
        transport.emit(.call(true))
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testPendingHandBackIsForgottenWhenTheLinkGoesDown() {
        transport.supportsAudio = true
        engine.takeCallsOnMac = true
        makeActive()
        engine.handBackAudioToPhone(.userRequest) // the transport may drop it if the link goes down
        transport.emit(.linkStateChanged(.disconnected))
        transport.bringUp(call: true)
        transport.emit(.audioConnectionChanged(isOpen: true))
        transport.emit(.audioConnectionChanged(isOpen: false))
        XCTAssertEqual(engine.lastAudioFallback?.reason, .audioDropped, "a real drop is still reported")
    }

    func testLinkSetupBlockedIsExposed() {
        transport.emit(.linkSetupBlocked(true))
        XCTAssertTrue(engine.isLinkSetupBlocked)
        transport.emit(.linkSetupBlocked(false))
        XCTAssertFalse(engine.isLinkSetupBlocked)
    }

    func testSleepAndWakeAreForwarded() {
        engine.prepareForSleep()
        engine.systemDidWake()
        engine.reconnect()
        engine.start()
        engine.stop()
        XCTAssertEqual(transport.commands, [.prepareForSleep, .resumeAfterSleep, .reconnect, .connect, .disconnect])
    }

    func testInvalidateShutsDownTransportAndEndsLiveCall() {
        makeActive()
        engine.invalidate()
        engine.invalidate() // idempotent
        XCTAssertEqual(transport.count(.invalidate), 1)
        XCTAssertNil(transport.eventHandler)
        XCTAssertEqual(engine.linkState, .disconnected)
        XCTAssertEqual(engine.call?.endReason, .connectionLost)
        XCTAssertThrowsError(try engine.dial(DialNumber("123")!)) {
            XCTAssertEqual($0 as? CallEngineError, .notConnected)
        }
    }

    // MARK: Audio fallback hook

    func testRemoteControlModeHandsSCOBackToThePhone() {
        makeActive()
        XCTAssertFalse(engine.isAudioOnMacEnabled)
        transport.emit(.audioConnectionChanged(isOpen: true))
        XCTAssertEqual(transport.commands, [.transferAudioToPhone])
        XCTAssertEqual(engine.lastAudioFallback?.reason, .audioOnMacDisabled)
        transport.emit(.audioConnectionChanged(isOpen: false))
        XCTAssertEqual(engine.audioRoute, .phone)
    }

    func testSCOOpenedDuringLinkSetUpIsHandedBack() {
        transport.emit(.linkStateChanged(.disconnected))
        transport.clearCommands()
        transport.emit(.linkStateChanged(.connecting))
        transport.emit(.call(true))
        transport.emit(.audioConnectionChanged(isOpen: true)) // phone opens SCO before the SLC is up
        XCTAssertEqual(transport.commands, [.transferAudioToPhone])
        XCTAssertEqual(engine.lastAudioFallback?.reason, .audioOnMacDisabled)
    }

    func testFailedHandBackIsRetriedWhenTheLinkIsUp() {
        transport.emit(.linkStateChanged(.disconnected))
        transport.clearCommands()
        transport.failTransferAudio = true
        transport.emit(.linkStateChanged(.connecting))
        transport.emit(.audioConnectionChanged(isOpen: true))
        XCTAssertNil(engine.lastAudioFallback, "no notice for a transfer that did not happen")
        XCTAssertEqual(engine.audioRoute, .mac)

        transport.failTransferAudio = false
        transport.emit(.linkStateChanged(.connected))
        transport.emit(.audioConnectionChanged(isOpen: true)) // the transport re-reports SCO after connected
        XCTAssertEqual(transport.count(.transferAudioToPhone), 1)
        XCTAssertEqual(engine.lastAudioFallback?.reason, .audioOnMacDisabled)
        transport.emit(.audioConnectionChanged(isOpen: false))
        XCTAssertEqual(engine.audioRoute, .phone)
    }

    func testClosedSCOReportedAfterConnectIsHarmless() {
        transport.emit(.audioConnectionChanged(isOpen: false))
        XCTAssertNil(engine.lastAudioFallback)
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testTakeCallsSettingAloneDoesNotEnableAudio() {
        engine.takeCallsOnMac = true
        XCTAssertFalse(engine.isAudioOnMacEnabled, "transport has no audio support")
    }

    func testAudioSetupTimeoutFallsBackWhenAudioIsEnabled() {
        transport.supportsAudio = true
        engine.takeCallsOnMac = true
        makeActive()
        scheduler.advance(by: engine.configuration.audioSetupTimeout + 0.1)
        XCTAssertEqual(transport.commands, [.transferAudioToPhone])
        XCTAssertEqual(engine.lastAudioFallback?.reason, .audioSetupTimedOut)
    }

    func testAudioDropIsReportedWhenAudioIsEnabled() {
        transport.supportsAudio = true
        engine.takeCallsOnMac = true
        makeActive()
        transport.emit(.audioConnectionChanged(isOpen: true))
        XCTAssertEqual(engine.audioRoute, .mac)
        transport.emit(.audioConnectionChanged(isOpen: false))
        XCTAssertEqual(engine.audioRoute, .phone)
        XCTAssertEqual(engine.lastAudioFallback?.reason, .audioDropped)
    }

    func testMoveToPhone() throws {
        makeActive()
        try engine.transferAudioToPhone()
        XCTAssertEqual(transport.commands, [.transferAudioToPhone])
        XCTAssertEqual(engine.lastAudioFallback?.reason, .userRequest)
    }
}
