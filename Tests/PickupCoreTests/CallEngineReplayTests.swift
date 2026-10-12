import XCTest
@testable import PickupCore

/// Replays the real Pixel 9 Pro transcript from phase 0 through the engine.
@MainActor
final class CallEngineReplayTests: XCTestCase {
    private func at(_ time: String) -> Date {
        LogReplayer.timestampFormatter.date(from: "2026-10-11T\(time)+02:00")!
    }

    private func makeReplayer() -> LogReplayer {
        LogReplayer(log: PixelPhase0Log.full)
    }

    func testFullTranscriptProducesTheExpectedCalls() {
        let replayer = makeReplayer()
        replayer.replay()

        XCTAssertTrue(replayer.engineErrors.isEmpty, "\(replayer.engineErrors)")
        let summary = replayer.finishedCalls.map { "\($0.direction.rawValue) \($0.endReason?.rawValue ?? "-")" }
        XCTAssertEqual(summary, [
            "incoming missed",
            "incoming remoteEnded",
            "incoming hungUp",
            "incoming declined",
            "incoming remoteEnded",
            "outgoing hungUp",
        ])
        XCTAssertEqual(replayer.engine.linkState, .disconnected)
        XCTAssertEqual(replayer.engine.phoneStatus, PhoneStatus())
    }

    func testSLCSetupYieldsIndicatorsAndNoCall() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:08:20.000"))

        XCTAssertEqual(replayer.engine.linkState, .connected)
        XCTAssertEqual(replayer.engine.phase, .idle)
        XCTAssertEqual(replayer.engine.phoneStatus, PhoneStatus(hasService: true, signal: 5, isRoaming: false, battery: 4))
        XCTAssertEqual(replayer.engine.indicators.callSetup, CallSetupState.none)
    }

    func testCallsetupOneStartsRingingAndRequestsTheCallList() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:08:47.000"))

        XCTAssertEqual(replayer.engine.phase, .ringing)
        XCTAssertEqual(replayer.engine.call?.direction, .incoming)
        XCTAssertEqual(replayer.engine.call?.callerID, .unknown)
        // No RING/+CLIP from the Pixel: the engine must ask for the list itself.
        XCTAssertEqual(replayer.transport.count(.requestCurrentCalls), 1)
    }

    func testMissedCall() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:09:11.500"))

        XCTAssertEqual(replayer.engine.phase, .ended)
        XCTAssertEqual(replayer.engine.call?.endReason, .missed)
        XCTAssertNil(replayer.engine.call?.connectedAt)
        XCTAssertEqual(replayer.transport.count(.endCall), 0)

        replayer.replay(until: at("11:09:20.000"))
        XCTAssertEqual(replayer.engine.phase, .idle)
    }

    func testAcceptedCallTracksDuration() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:12:16.000"))

        let call = replayer.finishedCalls.last
        XCTAssertEqual(call?.endReason, .remoteEnded)
        XCTAssertEqual(call?.connectedAt, at("11:12:03.608"))
        XCTAssertEqual(call?.duration(at: at("11:30:00.000")) ?? 0, 11.647, accuracy: 0.001)
        XCTAssertEqual(replayer.transport.count(.acceptCallOnPhone), 1)
    }

    func testNumberFromCallListThenDeclineWhileRinging() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:15:51.000"))
        XCTAssertEqual(replayer.engine.phase, .ringing)
        XCTAssertEqual(replayer.engine.call?.callerID, .number("+49*******515"))

        replayer.replay(until: at("11:16:03.000"))
        let call = replayer.finishedCalls.last
        XCTAssertEqual(call?.endReason, .declined)
        XCTAssertEqual(call?.number, "+49*******515")
    }

    func testOutgoingCallFlow() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:18:44.000"))
        XCTAssertEqual(replayer.engine.phase, .dialing)
        XCTAssertEqual(replayer.engine.call?.number, "+49*******515")
        XCTAssertEqual(replayer.engine.call?.isRemoteAlerting, false)
        XCTAssertEqual(replayer.transport.commands.last, .dial("+49*******515"))

        replayer.replay(until: at("11:18:46.000"))
        XCTAssertEqual(replayer.engine.phase, .dialing)
        XCTAssertEqual(replayer.engine.call?.isRemoteAlerting, true)

        replayer.replay(until: at("11:18:55.000"))
        XCTAssertEqual(replayer.engine.phase, .active)
        XCTAssertEqual(replayer.engine.call?.connectedAt, at("11:18:54.523"))

        replayer.replay(until: at("11:19:04.000"))
        let call = replayer.finishedCalls.last
        XCTAssertEqual(call?.direction, .outgoing)
        XCTAssertEqual(call?.endReason, .hungUp)
        XCTAssertEqual(call?.endedAt, at("11:19:03.048"))
    }

    func testDTMFDuringActiveCallIsSent() {
        let replayer = makeReplayer()
        replayer.replay(until: at("11:16:55.000"))
        XCTAssertEqual(replayer.engine.phase, .active)
        XCTAssertEqual(replayer.transport.commands.last, .sendDTMF("1"))
    }

    // MARK: Headset run: RING and +CLIP are sent

    func testHeadsetRunUsesRINGAndCLIP() {
        let replayer = LogReplayer(log: PixelHeadsetLog.full)
        replayer.replay(until: at("11:25:18.600"))
        XCTAssertEqual(replayer.engine.phase, .ringing)
        // +CLIP arrives 4 ms after callsetup=1: the number is known before any call list answer.
        XCTAssertEqual(replayer.engine.call?.callerID, .number("+49*******515"))

        replayer.replay()
        XCTAssertTrue(replayer.engineErrors.isEmpty, "\(replayer.engineErrors)")
        let call = replayer.finishedCalls.last
        XCTAssertEqual(replayer.finishedCalls.count, 1)
        XCTAssertEqual(call?.endReason, .hungUp)
        XCTAssertEqual(call?.number, "+49*******515")
        XCTAssertEqual(call?.connectedAt, at("11:25:23.466"))
        XCTAssertEqual(call?.endedAt, at("11:25:39.774"))
    }

    func testHeadsetRunCLIPLineIsSanitisedForTheLog() {
        let clip = PixelHeadsetLog.full.split(separator: "\n")
            .compactMap { LogReplayer.parse(String($0)) }
            .first { $0.message.hasPrefix("<< +CLIP:") }!
        var sanitizer = ATLogSanitizer()
        XCTAssertEqual(sanitizer.incoming(String(clip.message.dropFirst(3))), #"+CLIP: "+49*******515",145,,,"""#)
    }
}
