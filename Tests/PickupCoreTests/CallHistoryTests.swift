import XCTest
@testable import PickupCore

/// Recent calls: parsing the phone's call lists, the session list and the engine's refresh rules.
@MainActor
final class CallHistoryTests: XCTestCase {
    private var transport: MockHFPTransport!
    private var scheduler: ManualScheduler!
    private var engine: CallEngine!

    override func setUp() async throws {
        transport = MockHFPTransport()
        transport.supportsCallHistory = true
        scheduler = ManualScheduler()
        engine = CallEngine(transport: transport, scheduler: scheduler)
    }

    private var historyRequests: [CallHistoryList] {
        transport.commands.compactMap { if case .readCallHistory(let list) = $0 { list } else { nil } }
    }

    private func answerAll(_ entries: [CallHistoryEntry]?) {
        for list in CallHistoryList.allCases { transport.emit(.callHistory(list, entries)) }
    }

    // MARK: Parsing

    func testParsesCPBREntries() {
        XCTAssertEqual(ATParser.parseCPBR(#"+CPBR: 1,"+49300000123",145,"Jane Doe""#),
                       CallHistoryEntry(number: "+49300000123", name: "Jane Doe"))
        XCTAssertEqual(ATParser.parseCPBR(#"+CPBR: 2,"0300000123",129,"""#),
                       CallHistoryEntry(number: "0300000123"))
        XCTAssertEqual(ATParser.parseCPBR(#"+CPBR: 3,"0300000123",129,"Jane Doe/M""#)?.name, "Jane Doe",
                       "Android's number type suffix is removed")
        XCTAssertEqual(ATParser.parseCPBR(#"+CPBR: 4,"",128,"Unknown""#), CallHistoryEntry(number: ""),
                       "a withheld caller has no number and the phone's placeholder text is dropped")
        XCTAssertNil(ATParser.parseCPBR("+CPBR: (1-25),30,30"), "the test response is no entry")
        XCTAssertNil(ATParser.parseCPBR("+CLCC: 1,0,0,0,0"))
    }

    func testPhonebookCommandsAreRecognisedAndCollectTheirResponses() {
        XCTAssertEqual(HFPCommand(atCommand: #"AT+CPBS="DC""#), .selectPhonebook)
        XCTAssertEqual(HFPCommand(atCommand: "AT+CPBR=1,25"), .readPhonebook)
        XCTAssertEqual(HFPCommand.responsePrefix(of: "AT+CPBR=1,25"), "+CPBR")
        XCTAssertNil(HFPCommand.responsePrefix(of: #"AT+CPBS="DC""#))

        var tracker = ATExchangeTracker()
        tracker.outgoing("AT+CPBR=1,25")
        _ = tracker.incoming(#"+CPBR: 1,"+49300000123",145,"Jane Doe""#)
        _ = tracker.incoming(#"+CPBR: 2,"+49300000456",145,"""#)
        let outputs = tracker.incoming("OK")
        guard case .completed(let exchange)? = outputs.last else { return XCTFail("no exchange: \(outputs)") }
        XCTAssertEqual(exchange.command, .readPhonebook)
        XCTAssertEqual(exchange.responses.compactMap(ATParser.parseCPBR).map(\.number), ["+49300000123", "+49300000456"])
    }

    // MARK: Session list and display

    func testRunsOfTheSameNumberAreMerged() {
        let entries = [
            CallHistoryEntry(number: "+49 30 0000123"), CallHistoryEntry(number: "+49300000123", name: "Jane Doe"),
            CallHistoryEntry(number: "+49300000456"), CallHistoryEntry(number: "+49300000123"),
            CallHistoryEntry(number: ""), CallHistoryEntry(number: ""),
        ]
        let collapsed = CallHistory.collapsed(entries)
        XCTAssertEqual(collapsed.map(\.count), [2, 1, 1, 1, 1], "withheld calls are never merged")
        XCTAssertEqual(collapsed.first?.name, "Jane Doe")
    }

    func testFinishedCallsGoToTheSessionListUntilThePhoneSharesItsLists() {
        transport.supportsCallHistory = false
        transport.bringUp()
        // Missed incoming call.
        transport.emit(.callSetup(.incoming))
        transport.emit(.currentCalls([HFPCall(index: 1, direction: .incoming, status: .incoming, number: "+49300000123")]))
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 1)
        // Outgoing call.
        try? engine.dial(DialNumber("+49300000456")!)
        transport.emit(.callSetup(.outgoing))
        transport.emit(.callSetup(.none))
        scheduler.advance(by: 5)

        XCTAssertEqual(engine.callHistory.source(.missed), .session)
        XCTAssertEqual(engine.callHistory.entries(.missed).map(\.number), ["+49300000123"])
        XCTAssertEqual(engine.callHistory.entries(.dialed).map(\.number), ["+49300000456"])
        XCTAssertNotNil(engine.callHistory.entries(.dialed).first?.date, "session entries know when the call was")
        XCTAssertEqual(engine.callHistory.entries(.received), [])
        XCTAssertTrue(engine.callHistory.phoneRefused)

        engine.refreshCallHistory()   // the phone still does not share: the session list stays
        XCTAssertEqual(engine.callHistory.entries(.missed).count, 1)
    }

    func testListForAFinishedCall() {
        func call(_ direction: CallDirection, _ reason: CallEndReason, connected: Bool = false) -> CallInfo {
            var info = CallInfo(direction: direction, callerID: .number("+49300000123"), phase: .ended, startedAt: Date())
            info.endReason = reason
            if connected { info.connectedAt = Date() }
            return info
        }
        XCTAssertEqual(CallHistory.list(for: call(.incoming, .missed)), .missed)
        XCTAssertEqual(CallHistory.list(for: call(.incoming, .declined)), .missed)
        XCTAssertEqual(CallHistory.list(for: call(.incoming, .remoteEnded, connected: true)), .received)
        XCTAssertEqual(CallHistory.list(for: call(.outgoing, .unanswered)), .dialed)
        XCTAssertEqual(CallHistory.list(for: call(.outgoing, .hungUp, connected: true)), .dialed)
        XCTAssertNil(CallHistory.list(for: call(.outgoing, .failed)), "a refused dial never reached the phone's log")
    }

    // MARK: Engine refresh

    func testListsAreReadShortlyAfterTheLinkCameUp() {
        transport.bringUp()
        XCTAssertEqual(historyRequests, [], "not during the SLC set-up")
        scheduler.advance(by: 2)
        XCTAssertEqual(historyRequests, CallHistoryList.allCases)
        XCTAssertTrue(engine.callHistory.isLoading)

        transport.emit(.callHistory(.dialed, [CallHistoryEntry(number: "+49300000123", name: "Jane Doe")]))
        XCTAssertEqual(engine.callHistory.source(.dialed), .phone)
        XCTAssertEqual(engine.callHistory.entries(.dialed).first?.name, "Jane Doe")
        XCTAssertTrue(engine.callHistory.isLoading)
        transport.emit(.callHistory(.received, []))
        transport.emit(.callHistory(.missed, []))
        XCTAssertFalse(engine.callHistory.isLoading)
        XCTAssertFalse(engine.callHistory.phoneRefused)
    }

    func testRefreshIsThrottledAndSkippedDuringACall() {
        transport.bringUp()
        scheduler.advance(by: 2)
        answerAll([])
        transport.clearCommands()

        engine.refreshCallHistory()
        XCTAssertEqual(historyRequests, [], "requested less than the minimum interval ago")

        scheduler.advance(by: 20)
        transport.emit(.callSetup(.incoming))
        transport.clearCommands()
        engine.refreshCallHistory()
        XCTAssertEqual(historyRequests, [], "never while a call is live")
    }

    func testListsAreReadAgainAfterACallEnded() {
        transport.bringUp()
        scheduler.advance(by: 2)
        answerAll([])
        transport.emit(.callSetup(.incoming))
        transport.emit(.callSetup(.none))
        transport.clearCommands()
        scheduler.advance(by: 3)
        XCTAssertEqual(historyRequests, CallHistoryList.allCases)
    }

    func testAPhoneThatRefusedIsNotAskedAgainAutomatically() {
        transport.bringUp()
        scheduler.advance(by: 2)
        answerAll(nil)
        XCTAssertTrue(engine.callHistory.phoneRefused)
        transport.emit(.callSetup(.incoming))
        transport.emit(.callSetup(.none))
        transport.clearCommands()
        scheduler.advance(by: 30)
        XCTAssertEqual(historyRequests, [])

        engine.refreshCallHistory()   // the dialer opened: ask again
        XCTAssertEqual(historyRequests, CallHistoryList.allCases)
    }

    func testLinkLossCancelsOutstandingReads() {
        transport.bringUp()
        scheduler.advance(by: 2)
        XCTAssertTrue(engine.callHistory.isLoading)
        transport.emit(.linkStateChanged(.disconnected))
        XCTAssertFalse(engine.callHistory.isLoading)
    }

    func testEntryDescriptionNeverContainsPersonalData() {
        let entry = CallHistoryEntry(number: "+49300000123", name: "Jane Doe")
        for text in ["\(entry)", String(reflecting: entry), "\(TransportEvent.callHistory(.dialed, [entry]))"] {
            XCTAssertFalse(text.contains("0000123"), text)
            XCTAssertFalse(text.contains("Jane"), text)
        }
    }

    // MARK: Unanswered reads

    /// Regression (2026-10-30): a read the phone never answered left the dialer loading forever.
    func testUnansweredReadEndsLoadingWithoutCountingAsRefused() {
        transport.bringUp()
        scheduler.advance(by: 2)
        XCTAssertTrue(engine.callHistory.isLoading)
        for list in CallHistoryList.allCases { transport.emit(.callHistoryUnanswered(list)) }
        XCTAssertFalse(engine.callHistory.isLoading)
        XCTAssertFalse(engine.callHistory.phoneRefused, "no answer is not a refusal: no hint about the phone's permission")
        XCTAssertTrue(engine.callHistory.lastReadUnanswered)
        transport.emit(.callHistory(.dialed, []))
        XCTAssertFalse(engine.callHistory.lastReadUnanswered, "a later answer clears it")
    }
}
