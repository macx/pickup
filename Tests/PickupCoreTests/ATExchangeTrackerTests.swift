import XCTest
@testable import PickupCore

/// Fixtures are lines from the Pixel 9 Pro phase 0 log (numbers abbreviated).
final class ATExchangeTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Feeds one incoming line and expects exactly one output.
    private func single(_ tracker: inout ATExchangeTracker, _ line: String, at date: Date? = nil,
                        file: StaticString = #filePath, line number: UInt = #line) -> ATExchangeTracker.Output? {
        let outputs = tracker.incoming(line, at: date ?? t0)
        XCTAssertEqual(outputs.count, 1, "\(outputs)", file: file, line: number)
        return outputs.first
    }

    private func completed(_ output: ATExchangeTracker.Output?) -> ATExchange? {
        if case .completed(let exchange) = output { return exchange }
        return nil
    }

    func testCLCCExchangeFromPixel() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CLCC", at: t0)
        let entry = single(&tracker, #"+CLCC: 1,1,4,0,0,"+49*******515",145"#)
        guard case .response(.currentCall(let call)) = entry else {
            return XCTFail("expected a +CLCC response, got \(String(describing: entry))")
        }
        XCTAssertEqual(call.status, .incoming)

        guard let exchange = completed(single(&tracker, "OK")) else { return XCTFail("expected completion") }
        XCTAssertEqual(exchange.command, .currentCalls)
        XCTAssertEqual(exchange.result, .ok)
        XCTAssertEqual(exchange.currentCalls, [
            HFPCall(index: 1, direction: .incoming, status: .incoming, number: "+49*******515", numberType: 145),
        ])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testEmptyCallListDuringSLC() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CLCC", at: t0)
        XCTAssertEqual(completed(single(&tracker, "OK"))?.currentCalls, [])
    }

    func testUnsolicitedLinesBetweenCommandAndResult() {
        // From the SLC: +BSIR arrives while AT+CHLD=? is pending.
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CHLD=?", at: t0)
        XCTAssertEqual(single(&tracker, "+BSIR: 0"), .unsolicited(.unknown("+BSIR: 0")))
        XCTAssertEqual(single(&tracker, "+BSIR: 1"), .unsolicited(.unknown("+BSIR: 1")))
        XCTAssertEqual(single(&tracker, "+CHLD: (0,1,2,3)"), .response(.unknown("+CHLD: (0,1,2,3)")))
        let exchange = completed(single(&tracker, "OK"))
        XCTAssertEqual(exchange?.command, .other("AT+CHLD=?"))
        XCTAssertEqual(exchange?.responses, ["+CHLD: (0,1,2,3)"])
    }

    func testSetCommandDoesNotSwallowUnsolicitedResultOfTheSameName() {
        // AT+CLIP=1 is pending while a call rings: +CLIP is unsolicited, not its response.
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CLIP=1", at: t0)
        XCTAssertEqual(single(&tracker, #"+CLIP: "+49*******515",145"#), .unsolicited(.callerID(number: "+49*******515")))
        XCTAssertEqual(completed(single(&tracker, "OK"))?.command, .other("AT+CLIP="))
    }

    func testBRSFSetCommandGetsItsResponse() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+BRSF=116", at: t0)
        XCTAssertEqual(single(&tracker, "+BRSF: 879"), .response(.unknown("+BRSF: 879")))
    }

    func testIndicatorAfterOKIsUnsolicited() {
        // Accept: ATA -> OK, then +CIEV call=1 and callsetup=0.
        var tracker = ATExchangeTracker()
        tracker.outgoing("ATA", at: t0)
        XCTAssertEqual(completed(single(&tracker, "OK"))?.command, .accept)
        XCTAssertEqual(single(&tracker, "+CIEV: 1,1"), .unsolicited(.indicator(index: 1, value: 1)))
        XCTAssertEqual(single(&tracker, "+CIEV: 2,0"), .unsolicited(.indicator(index: 2, value: 0)))
    }

    func testDialErrorIsCorrelated() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("ATD+49*******515;", at: t0)
        let exchange = completed(single(&tracker, "+CME ERROR: 30"))
        XCTAssertEqual(exchange?.command, .dial)
        XCTAssertEqual(exchange?.result, .cmeError(30))
    }

    func testCMSErrorIsAFinalResult() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CSMS=?", at: t0)
        XCTAssertEqual(completed(single(&tracker, "+CMS ERROR: 302"))?.result, .cmsError(302))
        tracker.outgoing("AT+CLCC", at: t0)
        XCTAssertEqual(completed(single(&tracker, "OK"))?.command, .currentCalls)
    }

    func testSMSProbingErrorsDoNotLeakIntoLaterCommands() {
        var tracker = ATExchangeTracker()
        for command in ["AT+CSMS=?", "AT+CSMS?", "AT+CMGF=?", "AT+CNMI=?", "AT+CNMI=3,1,0,0,0"] {
            tracker.outgoing(command, at: t0)
            XCTAssertEqual(completed(single(&tracker, "ERROR"))?.result, .error)
        }
        tracker.outgoing("AT+CSCS=\"UTF-8\"", at: t0)
        XCTAssertEqual(completed(single(&tracker, "OK"))?.command, .other("AT+CSCS="))
    }

    func testFailedWriteIsDroppedSoTheNextResultIsNotMisattributed() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("ATD+49*******515;", at: t0)
        XCTAssertEqual(tracker.writeFailed(), [.discarded(.dial)])
        tracker.outgoing("AT+CLCC", at: t0)
        XCTAssertEqual(completed(single(&tracker, "ERROR"))?.command, .currentCalls,
                       "the ERROR must not end the call as a failed dial")
    }

    func testResyncWhenAResponseBelongsToALaterCommand() {
        // The reply to AT+VGS=7 got lost; the +CLCC lines must still reach AT+CLCC.
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+VGS=7", at: t0)
        tracker.outgoing("AT+CLCC", at: t0)
        let outputs = tracker.incoming(#"+CLCC: 1,1,4,0,0,"+49*******515",145"#, at: t0)
        XCTAssertEqual(outputs.first, .discarded(.other("AT+VGS=")))
        XCTAssertEqual(outputs.count, 2)
        let exchange = completed(single(&tracker, "OK"))
        XCTAssertEqual(exchange?.command, .currentCalls)
        XCTAssertEqual(exchange?.currentCalls.first?.number, "+49*******515")
    }

    func testStaleEntriesExpire() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("ATD+49*******515;", at: t0) // never answered
        tracker.outgoing("AT+CLCC", at: t0.addingTimeInterval(10))
        let outputs = tracker.incoming("ERROR", at: t0.addingTimeInterval(10.1))
        XCTAssertEqual(outputs.count, 1, "the dial already expired when AT+CLCC was sent")
        XCTAssertEqual(completed(outputs.first)?.command, .currentCalls)

        tracker.outgoing("AT+CLCC", at: t0.addingTimeInterval(20))
        let late = tracker.incoming("OK", at: t0.addingTimeInterval(26))
        XCTAssertEqual(late, [.discarded(.currentCalls), .unsolicited(.ok)])
    }

    func testFinalResultWithoutCommandIsUnsolicited() {
        var tracker = ATExchangeTracker()
        XCTAssertEqual(single(&tracker, "OK"), .unsolicited(.ok))
    }

    func testResetDropsPendingCommands() {
        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CLCC", at: t0)
        tracker.reset()
        XCTAssertEqual(single(&tracker, "OK"), .unsolicited(.ok))
    }

    func testPendingQueueIsBounded() {
        var tracker = ATExchangeTracker()
        var discarded = 0
        for _ in 0..<20 { discarded += tracker.outgoing("AT+CIND?", at: t0).count }
        XCTAssertEqual(tracker.pendingCount, ATExchangeTracker.maximumPending)
        XCTAssertEqual(discarded, 20 - ATExchangeTracker.maximumPending)
    }

    func testCommandClassificationNeverKeepsArguments() {
        XCTAssertEqual(HFPCommand(atCommand: "ATD015112345678;"), .dial)
        XCTAssertEqual(HFPCommand(atCommand: "AT+VTS=1"), .dtmf)
        XCTAssertEqual(HFPCommand(atCommand: "AT+CHUP"), .endCall)
        XCTAssertEqual(HFPCommand(atCommand: "AT+BRSF=116"), .other("AT+BRSF="))
        XCTAssertEqual(HFPCommand(atCommand: "AT+CIND=?"), .other("AT+CIND=?"))
        XCTAssertEqual(HFPCommand(atCommand: "AT+CIND?"), .other("AT+CIND?"))
    }
}

final class HFPIndicatorMapTests: XCTestCase {
    // Pixel 9 Pro, Android 17.
    let pixelCIND = #"+CIND: ("call",(0,1)),("callsetup",(0-3)),("service",(0-1)),("signal",(0-5)),("roam",(0,1)),("battchg",(0-5)),("callheld",(0-2))"#

    func testParsesPixelOrder() {
        let map = HFPIndicatorMap(testResponse: pixelCIND)
        XCTAssertEqual(map?.names, ["call", "callsetup", "service", "signal", "roam", "battchg", "callheld"])
    }

    func testMapsCIEV() {
        let map = HFPIndicatorMap(testResponse: pixelCIND)!
        XCTAssertEqual(map.indicator(index: 2, value: 1), .callSetup(.incoming))
        XCTAssertEqual(map.indicator(index: 2, value: 3), .callSetup(.remoteAlerting))
        XCTAssertEqual(map.indicator(index: 1, value: 1), .call(true))
        XCTAssertEqual(map.indicator(index: 4, value: 4), .signal(4))
        XCTAssertEqual(map.indicator(index: 7, value: 2), .callHeld(.heldOnly))
        XCTAssertNil(map.indicator(index: 8, value: 1))
        XCTAssertNil(map.indicator(index: 2, value: 9))
    }

    func testMapsReadResponse() {
        let map = HFPIndicatorMap(testResponse: pixelCIND)!
        XCTAssertEqual(map.indicators(fromReadResponse: "+CIND: 0,0,1,5,0,4,0"), [
            .call(false), .callSetup(.none), .service(true), .signal(5), .roaming(false), .battery(4), .callHeld(.none),
        ])
    }

    func testRejectsOtherLines() {
        XCTAssertNil(HFPIndicatorMap(testResponse: "+CIND: 0,0,1,5,0,4,0"))
        XCTAssertNil(HFPIndicatorMap(testResponse: "OK"))
    }
}
