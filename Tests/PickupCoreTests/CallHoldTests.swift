import XCTest
@testable import PickupCore

/// Three-way calling: hold/resume, call waiting (hold and take, end and take, reject), swapping and
/// ending one of two calls. The phone's indicators may arrive before or after its OK.
@MainActor
final class CallHoldTests: XCTestCase {
    private var transport: MockHFPTransport!
    private var scheduler: ManualScheduler!
    private var engine: CallEngine!
    private var finished: [CallInfo] = []

    private let jane = "+49300000123"
    private let john = "+49300000456"

    override func setUp() async throws {
        transport = MockHFPTransport()
        transport.supportsCallHold = true
        scheduler = ManualScheduler()
        engine = CallEngine(transport: transport, scheduler: scheduler)
        engine.onCallFinished = { [weak self] in self?.finished.append($0) }
        transport.bringUp()
    }

    private var holdCommands: [CallHoldAction] {
        transport.commands.compactMap { if case .callHold(let action) = $0 { action } else { nil } }
    }

    /// Jane's incoming call, answered.
    private func activeCallWithJane() {
        transport.emit(.callSetup(.incoming))
        transport.emit(.currentCalls([HFPCall(index: 1, direction: .incoming, status: .incoming, number: jane)]))
        transport.emit(.call(true))
        transport.emit(.callSetup(.none))
        XCTAssertEqual(engine.phase, .active)
    }

    /// John calls while the call with Jane is active.
    private func johnWaits() {
        transport.emit(.callSetup(.incoming))
        transport.emit(.callWaiting(john))
        XCTAssertEqual(engine.waitingCall?.number, john)
    }

    private func ok() { transport.emit(.commandCompleted(.callHold, .ok)) }

    // MARK: Single call

    func testHoldAndResumeASingleCall() throws {
        activeCallWithJane()
        try engine.toggleHold()
        XCTAssertEqual(holdCommands, [.holdActiveAcceptOther])
        ok()
        transport.emit(.callHeld(.heldOnly))
        XCTAssertEqual(engine.phase, .held)

        try engine.toggleHold()
        ok()
        transport.emit(.callHeld(.none))
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.call?.number, jane)
    }

    func testPhonesWithoutThreeWayCallingRefuse() {
        transport.supportsCallHold = false
        activeCallWithJane()
        XCTAssertThrowsError(try engine.toggleHold()) { XCTAssertEqual($0 as? CallEngineError, .unsupported) }
        XCTAssertFalse(engine.supportsCallHold)
    }

    // MARK: Call waiting

    func testHoldAndTakeTheWaitingCallOKFirst() throws {
        activeCallWithJane()
        johnWaits()
        try engine.acceptWaitingCall(endingCurrent: false)
        XCTAssertEqual(holdCommands, [.holdActiveAcceptOther])
        ok()
        transport.emit(.callSetup(.none))
        transport.emit(.callHeld(.activeAndHeld))
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.heldCall?.number, jane)
        XCTAssertEqual(engine.heldCall?.phase, .held)
        XCTAssertNil(engine.waitingCall)
    }

    func testHoldAndTakeTheWaitingCallIndicatorsFirst() throws {
        activeCallWithJane()
        johnWaits()
        try engine.acceptWaitingCall(endingCurrent: false)
        transport.emit(.callHeld(.activeAndHeld))
        transport.emit(.callSetup(.none))
        ok()
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertEqual(engine.heldCall?.number, jane)
    }

    func testWaitingCallTakenOnThePhoneIsRecognised() {
        activeCallWithJane()
        johnWaits()
        transport.emit(.callSetup(.none))   // no request from this Mac
        transport.emit(.callHeld(.activeAndHeld))
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertEqual(engine.heldCall?.number, jane)
    }

    func testEndAndTakeTheWaitingCall() throws {
        activeCallWithJane()
        johnWaits()
        try engine.acceptWaitingCall(endingCurrent: true)
        XCTAssertEqual(holdCommands, [.releaseActiveAcceptOther])
        transport.emit(.callSetup(.none))
        ok()
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(finished.map(\.number), [jane])
        XCTAssertEqual(finished.first?.endReason, .hungUp)
    }

    func testRejectTheWaitingCall() throws {
        activeCallWithJane()
        johnWaits()
        try engine.rejectWaitingCall()
        XCTAssertEqual(holdCommands, [.releaseHeldOrRejectWaiting])
        ok()
        transport.emit(.callSetup(.none))
        XCTAssertNil(engine.waitingCall)
        XCTAssertEqual(engine.call?.number, jane)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.callHistory.entries(.missed).map(\.number), [john], "a rejected waiting call is in the missed list")
    }

    func testRejectedCommandLeavesTheCallsAlone() throws {
        activeCallWithJane()
        johnWaits()
        try engine.acceptWaitingCall(endingCurrent: false)
        transport.emit(.commandCompleted(.callHold, .error))
        XCTAssertEqual(engine.lastCommandFailure?.command, .callHold)
        XCTAssertEqual(engine.call?.number, jane)
        XCTAssertEqual(engine.waitingCall?.number, john)
        XCTAssertNil(engine.heldCall)
    }

    // MARK: Two calls

    private func janeHeldJohnActive() throws {
        activeCallWithJane()
        johnWaits()
        try engine.acceptWaitingCall(endingCurrent: false)
        ok()
        transport.emit(.callSetup(.none))
        transport.emit(.callHeld(.activeAndHeld))
        transport.clearCommands()
    }

    func testSwapCalls() throws {
        try janeHeldJohnActive()
        try engine.swapCalls()
        XCTAssertEqual(holdCommands, [.holdActiveAcceptOther])
        ok()
        XCTAssertEqual(engine.call?.number, jane)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertEqual(engine.heldCall?.number, john)
        XCTAssertEqual(engine.heldCall?.phase, .held)
    }

    func testHangingUpTheActiveCallResumesTheHeldOne() throws {
        try janeHeldJohnActive()
        try engine.hangUp()
        XCTAssertEqual(holdCommands, [.releaseActiveAcceptOther], "not AT+CHUP: the held call comes back")
        transport.emit(.callHeld(.none))
        ok()
        XCTAssertEqual(engine.call?.number, jane)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(finished.last?.number, john)
        XCTAssertEqual(finished.last?.endReason, .hungUp)
    }

    /// Found by the fuzz test: a phone without three-way calling may still report a second call; hanging
    /// up must not be blocked by the missing CHLD support.
    func testHangUpWorksWithASecondCallButNoThreeWayCalling() throws {
        transport.supportsCallHold = false
        activeCallWithJane()
        transport.emit(.callHeld(.activeAndHeld))
        XCTAssertNotNil(engine.heldCall)
        transport.clearCommands()
        XCTAssertNoThrow(try engine.hangUp())
        XCTAssertEqual(transport.commands, [.endCall])
    }

    func testEndTheHeldCall() throws {
        try janeHeldJohnActive()
        try engine.endHeldCall()
        XCTAssertEqual(holdCommands, [.releaseHeldOrRejectWaiting])
        ok()
        transport.emit(.callHeld(.none))
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertEqual(engine.phase, .active)
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(finished.last?.number, jane)
    }

    func testOtherPartyOfTheActiveCallHangsUp() throws {
        try janeHeldJohnActive()
        transport.emit(.callHeld(.heldOnly))
        XCTAssertEqual(engine.call?.number, jane)
        XCTAssertEqual(engine.phase, .held, "the held call stays on hold until the user resumes it")
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(finished.last?.endReason, .remoteEnded)
    }

    func testOtherPartyOfTheHeldCallHangsUp() throws {
        try janeHeldJohnActive()
        transport.emit(.callHeld(.none))
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(finished.last?.number, jane)
        XCTAssertEqual(finished.last?.endReason, .remoteEnded)
    }

    func testAllCallsEnd() throws {
        try janeHeldJohnActive()
        transport.emit(.call(false))
        XCTAssertEqual(engine.phase, .ended)
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(Set(finished.compactMap(\.number)), [jane, john])
    }

    func testLinkLossEndsBothCalls() throws {
        try janeHeldJohnActive()
        transport.emit(.linkStateChanged(.disconnected))
        XCTAssertNil(engine.heldCall)
        XCTAssertEqual(finished.filter { $0.endReason == .connectionLost }.count, 2)
    }

    func testCallListFillsInTheHeldNumber() {
        activeCallWithJane()
        transport.emit(.callHeld(.activeAndHeld))   // a second call dialed on the phone
        XCTAssertEqual(engine.heldCall?.number, jane)
        transport.emit(.currentCalls([
            HFPCall(index: 1, direction: .incoming, status: .held, number: jane),
            HFPCall(index: 2, direction: .outgoing, status: .active, number: john),
        ]))
        XCTAssertEqual(engine.call?.number, john)
        XCTAssertEqual(engine.call?.direction, .outgoing)
    }

    func testCallHoldCommandIsRecognised() {
        XCTAssertEqual(HFPCommand(atCommand: "AT+CHLD=2"), .callHold)
        XCTAssertEqual(HFPCommand(atCommand: "AT+CHLD=?"), .other("AT+CHLD=?"))
        XCTAssertNil(HFPCommand.responsePrefix(of: "AT+CHLD=1"))
    }

    // MARK: Review fixes (PR #7)

    func testSwapIsRefusedWhileAThirdCallerWaits() throws {
        try janeHeldJohnActive()
        transport.emit(.callSetup(.incoming))
        transport.emit(.callWaiting("+49300000789"))
        XCTAssertThrowsError(try engine.swapCalls(), "CHLD=2 would take the waiting caller instead")
        XCTAssertEqual(holdCommands, [])
    }

    func testEndAndAcceptIsRefusedWhileTheCallIsOnHold() throws {
        activeCallWithJane()
        try engine.toggleHold()
        ok()
        transport.emit(.callHeld(.heldOnly))
        johnWaits()
        transport.clearCommands()
        XCTAssertThrowsError(try engine.acceptWaitingCall(endingCurrent: true), "CHLD=1 would leave the held call")
        XCTAssertNoThrow(try engine.acceptWaitingCall(endingCurrent: false))
    }

    func testOneHoldCommandAtATimeAndAnUnansweredOneIsGivenUp() throws {
        try janeHeldJohnActive()
        try engine.swapCalls()
        XCTAssertTrue(engine.isCallHoldPending)
        XCTAssertThrowsError(try engine.endHeldCall(), "the swap's reply must not be taken for this command")
        scheduler.advance(by: engine.configuration.callHoldReplyTimeout)
        XCTAssertFalse(engine.isCallHoldPending)
        XCTAssertNoThrow(try engine.endHeldCall())
    }

    func testAWaitingCallerWhoGivesUpIsAMissedCall() {
        activeCallWithJane()
        johnWaits()
        transport.emit(.callSetup(.none))   // John hangs up before anyone answers
        XCTAssertTrue(finished.isEmpty)
        scheduler.advance(by: engine.configuration.waitingCallTakenWindow)
        XCTAssertEqual(finished.last?.number, john)
        XCTAssertEqual(finished.last?.endReason, .missed)
        XCTAssertEqual(engine.callHistory.entries(.missed).map(\.number), [john])
    }

    func testCallsSwappedOnThePhoneAreFollowed() throws {
        try janeHeldJohnActive()   // John active, Jane held
        transport.emit(.callHeld(.activeAndHeld))   // the phone repeats callheld=1 after a swap
        XCTAssertTrue(transport.commands.contains(.requestCurrentCalls))
        let janeID = engine.heldCall?.id
        transport.emit(.currentCalls([
            HFPCall(index: 1, direction: .incoming, status: .active, number: jane),
            HFPCall(index: 2, direction: .incoming, status: .held, number: john),
        ]))
        XCTAssertEqual(engine.call?.number, jane)
        XCTAssertEqual(engine.call?.id, janeID, "the call keeps its identity and times")
        XCTAssertEqual(engine.heldCall?.number, john)
    }
}
