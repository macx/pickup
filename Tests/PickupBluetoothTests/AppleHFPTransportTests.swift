import XCTest
import PickupBluetoothShim
import PickupCore
@testable import PickupBluetooth

/// Transport state machine against a fake hands-free object. Regression tests for the reconnect
/// crash of 2026-10-11 (two hands-free objects answered the phone's reconnect).
@MainActor
final class AppleHFPTransportTests: XCTestCase {
    final class FakeLink: HandsFreeLink {
        let channel = NSObject()
        var isConnected = false
        var isSCOConnected = false
        var isACLConnected = true
        /// The real stack sometimes never confirms; then isConnected may or may not drop.
        var disconnectDropsSLC = false
        var onClosed: (@MainActor () -> Void)?
        var deviceName: String? = "Pixel 9 Pro"
        var audioGatewayFeatures: UInt32 = 0
        var callHoldModes: UInt32 = 0
        var underlying: AnyObject { self }
        private(set) var calls: [String] = []
        private(set) var delegates: [HandsFreeDelegate] = []

        func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

        func attach(delegate: HandsFreeDelegate, incoming: @escaping PUBATLogHandler) {
            delegates.append(delegate)
            calls.append("attach")
        }
        func park(onClosed: @escaping @MainActor () -> Void) {
            calls.append("park")
            self.onClosed = onClosed
        }
        func connect() { calls.append("connect") }
        func disconnect() {
            calls.append("disconnect")
            if disconnectDropsSLC { isConnected = false }
        }
        func acceptCallOnPhone() { calls.append("ATA") }
        func endCall() { calls.append("CHUP") }
        func dialNumber(_ number: String) { calls.append("ATD") }
        func sendDTMF(_ digit: String) { calls.append("VTS") }
        func transferAudioToPhone() { calls.append("phone") }
        func currentCallList() { calls.append("CLCC") }
        func sendATCommand(_ line: String) { calls.append(line) }
        func owns(channel: AnyObject) -> Bool { channel === self.channel }
        func indicatorSnapshot() -> [HFPIndicator] { [.call(false), .callSetup(.none)] }
        func diagnostics() -> [String] { [] }
    }

    final class Clock: Scheduler {
        private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
        private var tasks: [(due: Date, order: Int, action: @MainActor () -> Void, task: Task)] = []
        private var order = 0
        final class Task: ScheduledTask { var cancelled = false; func cancel() { cancelled = true } }

        func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
            order += 1
            let task = Task()
            tasks.append((now.addingTimeInterval(delay), order, action, task))
            return task
        }

        func advance(by interval: TimeInterval) {
            let target = now.addingTimeInterval(interval)
            while let next = tasks.filter({ !$0.task.cancelled && $0.due <= target })
                .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
                tasks.removeAll { $0.task === next.task }
                now = next.due
                next.action()
            }
            now = target
        }
    }

    private var registry: HandsFreeRegistry!
    private var clock: Clock!
    private var made: [FakeLink] = []
    private var events: [TransportEvent] = []

    override func setUp() async throws {
        clock = Clock()
        let clock = self.clock!
        registry = HandsFreeRegistry(now: { clock.now })
        made = []
        events = []
    }

    private func makeTransport(address: String = "aa-bb-cc-dd-ee-ff", assumeOutgoingTap: Bool = true) -> AppleHFPTransport {
        var environment = AppleHFPTransport.Environment(
            makeLink: { [unowned self] _, _ in
                let link = FakeLink()
                self.made.append(link)
                return link
            },
            observeDeviceConnects: { _ in nil },
            installOutgoingTap: false,
            registry: registry
        )
        environment.assumeOutgoingTap = assumeOutgoingTap
        let transport = AppleHFPTransport(
            deviceAddress: address, log: NullDiagnosticLog(), scheduler: clock,
            policy: ReconnectPolicy(), timeouts: .init(), environment: environment
        )
        transport.eventHandler = { [unowned self] in self.events.append($0) }
        return transport
    }

    private func connected(_ transport: AppleHFPTransport) -> FakeLink {
        transport.connect()
        let link = made.last!
        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .connected)
        return link
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }

    private func dropped(_ transport: AppleHFPTransport, _ link: FakeLink) {
        link.isConnected = false
        transport.handsFree(link, disconnectedWithStatus: 0)
    }

    // MARK: One object per phone

    func testReconnectReusesTheSameHandsFreeObject() {
        let transport = makeTransport()
        let link = connected(transport)

        dropped(transport, link) // Bluetooth off on the phone
        XCTAssertEqual(transport.linkState, .disconnected)
        clock.advance(by: 2) // first backoff
        XCTAssertEqual(transport.linkState, .connecting)
        transport.handsFree(link, connectedWithStatus: Int32(bitPattern: 0xE00002C0)) // page timeout
        clock.advance(by: 4)

        XCTAssertEqual(made.count, 1, "never a second hands-free object for the same phone")
        XCTAssertEqual(link.count("connect"), 3)
    }

    func testPhoneInitiatedReconnectIsFollowedNotDuplicated() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        XCTAssertEqual(link.count("connect"), 1)

        // The Pixel comes back and connects to the Mac itself; IOBluetooth starts the SLC on our object.
        transport.sentLine("AT+BRSF=116", detail: "writeAsync", channel: link.channel)
        XCTAssertEqual(transport.linkState, .connecting)
        clock.advance(by: 10) // the scheduled backoff attempt must not start a second set-up
        XCTAssertEqual(link.count("connect"), 1)

        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .connected)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(link.count("connect"), 1)
    }

    func testSLCAlreadyUpOnAttemptIsAdopted() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        link.isConnected = true // the phone's set-up finished without us seeing AT+BRSF
        clock.advance(by: 2)
        XCTAssertEqual(transport.linkState, .connecting, "verified before adoption")
        XCTAssertEqual(link.count("CLCC"), 1)
        transport.sentLine("AT+CLCC", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertEqual(transport.linkState, .connected)
        XCTAssertEqual(link.count("connect"), 1)
    }

    func testPhoneReconnectAfterUserDisconnectIsClosedOutsideTheCallback() async {
        let transport = makeTransport()
        let link = connected(transport)
        transport.disconnect()
        dropped(transport, link)

        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel)
        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .disconnecting)
        XCTAssertEqual(link.count("disconnect"), 1, "not from inside IOBluetooth's connected callback")
        await drainMainQueue()
        XCTAssertEqual(link.count("disconnect"), 2)
    }

    func testOtherChannelWritesDoNotStartAnything() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        transport.sentLine("AT+BRSF=116", detail: nil, channel: NSObject())
        XCTAssertEqual(transport.linkState, .disconnected)
    }

    func testSecondTransportForTheSamePhoneWaitsForTheFirst() {
        let first = makeTransport()
        let link = connected(first)
        let second = makeTransport()
        second.connect()
        XCTAssertEqual(second.linkState, .disconnected, "refused: the object is owned by the first transport")
        XCTAssertEqual(made.count, 1)

        first.disconnect()
        dropped(first, link)
        first.invalidate()
        XCTAssertEqual(link.count("park"), 1)
        second.reconnect()
        XCTAssertEqual(made.count, 1, "the parked object is reused")
        XCTAssertEqual(link.count("attach"), 2)
        XCTAssertEqual(second.linkState, .connecting)
    }

    // MARK: H1a: parked object with a disconnect in flight

    func testReCheckoutWaitsForThePreviousOwnersDisconnect() async {
        let first = makeTransport()
        let link = connected(first)
        first.invalidate() // Settings re-creates the engine: park while the SLC is still up
        XCTAssertTrue(registry.isClosePending(address: "aa-bb-cc-dd-ee-ff"))

        events.removeAll()
        let second = makeTransport()
        second.connect()
        XCTAssertEqual(second.linkState, .disconnecting, "the dying SLC is not adopted")
        XCTAssertEqual(link.count("connect"), 1)
        XCTAssertFalse(events.contains(.linkStateChanged(.connected)))

        // The late disconnected callback now reaches the new owner's delegate.
        link.isConnected = false
        second.handsFree(link, disconnectedWithStatus: 0)
        XCTAssertFalse(registry.isClosePending(address: "aa-bb-cc-dd-ee-ff"))
        XCTAssertEqual(second.linkState, .connecting)
        await drainMainQueue()
        XCTAssertEqual(link.count("connect"), 2, "fresh connect after the old SLC is down")
    }

    func testPendingCloseThatNeverConfirmsIsGivenUp() {
        let first = makeTransport()
        let link = connected(first)
        first.invalidate()
        link.isConnected = false // went down, but no callback
        let second = makeTransport()
        second.connect()
        XCTAssertEqual(second.linkState, .disconnecting)
        clock.advance(by: 10)
        XCTAssertEqual(second.linkState, .connecting)
        XCTAssertEqual(link.count("connect"), 2)
    }

    // MARK: H1b: stale SLC after an unconfirmed disconnect

    private func unconfirmedSleep(_ transport: AppleHFPTransport, _ link: FakeLink) {
        transport.prepareForSleep()
        clock.advance(by: 31) // disconnect() twice more, never confirmed, isConnected stays true
        XCTAssertEqual(transport.linkState, .disconnected)
        XCTAssertEqual(link.count("disconnect"), 3)
    }

    func testStaleSLCIsVerifiedBeforeAdoption() {
        let transport = makeTransport()
        let link = connected(transport)
        unconfirmedSleep(transport, link)

        transport.resumeAfterSleep()
        XCTAssertEqual(transport.linkState, .connecting, "not adopted on isConnected alone")
        XCTAssertEqual(link.count("CLCC"), 1)
        transport.sentLine("AT+CLCC", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertEqual(transport.linkState, .connected)
    }

    func testStaleSLCWithoutAnswerIsClosed() {
        let transport = makeTransport()
        let link = connected(transport)
        unconfirmedSleep(transport, link)

        transport.resumeAfterSleep()
        clock.advance(by: 3.1)
        XCTAssertEqual(transport.linkState, .disconnecting)
        XCTAssertEqual(link.count("disconnect"), 4)
    }

    func testStaleSLCWithoutACLIsClosedWithoutProbing() {
        let transport = makeTransport()
        let link = connected(transport)
        unconfirmedSleep(transport, link)
        link.isACLConnected = false

        transport.resumeAfterSleep()
        XCTAssertEqual(transport.linkState, .disconnected, "no ACL: dead SLC, closed without the 3 x 10 s close")
        XCTAssertEqual(link.count("CLCC"), 0)
        XCTAssertEqual(link.count("disconnect"), 3, "no further disconnect()")
        XCTAssertNotNil(events.last(where: { if case .reconnectScheduled(.some) = $0 { return true } else { return false } }))
    }

    // MARK: M1 / M3: phone-started set-ups

    func testDisconnectDuringPhoneStartedSetupClosesTheLateSLC() async {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel)
        XCTAssertEqual(transport.linkState, .connecting)

        transport.disconnect()
        XCTAssertEqual(transport.linkState, .disconnecting)
        events.removeAll()
        link.isConnected = true
        transport.handsFree(link, indicator: .call(true)) // from the SLC set-up still running
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertFalse(events.contains(.indicator(.call(true))), "call events of an unwanted SLC are dropped")
        XCTAssertNotEqual(transport.linkState, .connected)
        await drainMainQueue()
        XCTAssertEqual(link.count("disconnect"), 2)
    }

    func testConnectTimerAdoptsAPhoneStartedSLCWithoutCallback() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel)
        link.isConnected = true // set-up completed, but no connected callback (unverified on hardware)
        clock.advance(by: 30)
        XCTAssertEqual(transport.linkState, .connecting, "verified before adoption")
        XCTAssertEqual(link.count("CLCC"), 1)
        transport.sentLine("AT+CLCC", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertEqual(transport.linkState, .connected)
        XCTAssertEqual(link.count("disconnect"), 0)
    }

    func testConnectTimerClosesAnSLCThatDoesNotAnswer() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel)
        link.isConnected = true
        clock.advance(by: 30 + 3.1)
        XCTAssertEqual(transport.linkState, .disconnecting)
        XCTAssertEqual(link.count("disconnect"), 1)
    }

    func testIndicatorEventsWhileDisconnectedAreDropped() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        events.removeAll()
        transport.handsFree(link, indicator: .callSetup(.incoming))
        transport.handsFreeRing(link)
        transport.handsFree(link, callerID: "+4930000123")
        transport.handsFree(link, audioOpened: true, status: 0)
        XCTAssertEqual(events, [.audioConnectionChanged(isOpen: true)])
    }

    // MARK: M4: ACL notification

    func testDeviceAppearedWaitsForThePhonesOwnReconnect() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link) // waiting 2 s for the first retry
        transport.handsFree(link, connectedWithStatus: Int32(bitPattern: 0xE00002C0))
        clock.advance(by: 2)
        transport.handsFree(link, connectedWithStatus: Int32(bitPattern: 0xE00002C0)) // now waiting 4 s
        let before = link.count("connect")

        transport.deviceAppeared()
        XCTAssertEqual(link.count("connect"), before, "no immediate connect()")
        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel) // the phone was faster
        clock.advance(by: 3)
        XCTAssertEqual(link.count("connect"), before)
        XCTAssertEqual(transport.linkState, .connecting)
    }

    func testDeviceAppearedConnectsIfThePhoneDoesNot() {
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        transport.handsFree(link, connectedWithStatus: Int32(bitPattern: 0xE00002C0))
        clock.advance(by: 2)
        transport.handsFree(link, connectedWithStatus: Int32(bitPattern: 0xE00002C0)) // waiting 4 s
        let before = link.count("connect")
        transport.deviceAppeared()
        clock.advance(by: 2.5)
        XCTAssertEqual(link.count("connect"), before + 1)
    }

    // MARK: No re-entry into IOBluetooth

    func testCommandsIssuedInsideCallbacksAreDeferred() async {
        let transport = makeTransport()
        let link = connected(transport)
        transport.eventHandler = { event in
            if case .indicator(.callSetup(.incoming)) = event {
                try? transport.requestCurrentCalls() // what CallEngine does on callsetup=1
            }
        }
        transport.handsFree(link, indicator: .callSetup(.incoming))
        XCTAssertEqual(link.count("CLCC"), 0, "not inside IOBluetooth's callback")
        await drainMainQueue()
        XCTAssertEqual(link.count("CLCC"), 1)
    }

    func testCommandsOutsideCallbacksRunImmediately() throws {
        let transport = makeTransport()
        let link = connected(transport)
        try transport.requestCurrentCalls()
        XCTAssertEqual(link.count("CLCC"), 1)
    }

    func testDeferredCommandIsDroppedWhenTheLinkWentDown() async {
        let transport = makeTransport()
        let link = connected(transport)
        transport.eventHandler = { event in
            if case .indicator = event { try? transport.endCall() }
        }
        transport.handsFree(link, indicator: .call(false))
        transport.eventHandler = nil
        dropped(transport, link)
        await drainMainQueue()
        XCTAssertEqual(link.count("CHUP"), 0)
    }

    // MARK: Unconfirmed disconnects

    func testRepeatedUnconfirmedDisconnectsReportBlockedAndRecover() {
        let transport = makeTransport()
        let link = connected(transport)
        link.disconnectDropsSLC = true // the SLC goes away, but IOBluetooth never says so
        transport.disconnect()
        clock.advance(by: 10) // 1st unconfirmed
        for _ in 0..<4 {
            transport.reconnect()
            clock.advance(by: 30 + 10 + 2) // connect times out, the close is never confirmed
        }
        XCTAssertTrue(events.contains(.linkSetupBlocked(true)))
        XCTAssertEqual(made.count, 1)

        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(events.last(where: { if case .linkSetupBlocked = $0 { return true } else { return false } }),
                       .linkSetupBlocked(false))
    }

    // MARK: Registry

    func testRegistryKeepsOneObjectPerAddress() {
        let ownerA = NSObject(), ownerB = NSObject()
        var creations = 0
        let make: () -> HandsFreeLink? = { creations += 1; return FakeLink() }
        let first = registry.checkOut(address: "a", owner: ownerA, make: make)
        XCTAssertTrue(first === registry.checkOut(address: "a", owner: ownerA, make: make))
        XCTAssertNil(registry.checkOut(address: "a", owner: ownerB, make: make))
        XCTAssertNotNil(registry.checkOut(address: "b", owner: ownerB, make: make))
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(registry.tag(for: "a"), "hf#1")
        XCTAssertEqual(registry.tag(for: "b"), "hf#2")

        registry.park(address: "a", owner: ownerB, linkMayBeUp: false) // not the owner: ignored
        XCTAssertNil(registry.checkOut(address: "a", owner: ownerB, make: make))
        registry.park(address: "a", owner: ownerA, linkMayBeUp: false)
        XCTAssertTrue(first === registry.checkOut(address: "a", owner: ownerB, make: make))
        XCTAssertEqual(registry.count, 2)
    }

    func testParkedCloseIsConfirmedByTheReaperOrTimesOut() {
        let owner = NSObject()
        let link = FakeLink()
        _ = registry.checkOut(address: "a", owner: owner, make: { link })
        registry.park(address: "a", owner: owner, linkMayBeUp: true)
        XCTAssertTrue(registry.isClosePending(address: "a"))
        link.onClosed?()
        XCTAssertFalse(registry.isClosePending(address: "a"))

        _ = registry.checkOut(address: "a", owner: owner, make: { nil })
        registry.park(address: "a", owner: owner, linkMayBeUp: true)
        clock.advance(by: registry.closeTimeout + 0.1)
        XCTAssertFalse(registry.isClosePending(address: "a"))
    }

    func testReleasedOwnerFreesTheObjectForTheNextOne() {
        var creations = 0
        let make: () -> HandsFreeLink? = { creations += 1; return FakeLink() }
        autoreleasepool {
            let owner = NSObject()
            _ = registry.checkOut(address: "a", owner: owner, make: make)
        }
        XCTAssertNotNil(registry.checkOut(address: "a", owner: NSObject(), make: make))
        XCTAssertEqual(creations, 1)
    }

    func testWritesAreRoutedToTheOwnerOfTheChannel() {
        let transport = makeTransport()
        let link = connected(transport)
        events.removeAll()
        registry.routeWrite("AT+CLCC", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertEqual(events, [.currentCalls([]), .commandCompleted(.currentCalls, .ok)])

        transport.invalidate()
        registry.routeWrite("AT+BRSF=116", detail: nil, channel: link.channel) // parked: logged only
        registry.routeWrite("AT+BRSF=116", detail: nil, channel: NSObject())   // unknown: logged only
    }

    // MARK: Third review

    func testNewOwnerVerifiesAStaleSLCInsteadOfAdoptingIt() {
        // M1: the previous owner's close was given up; isConnected still (wrongly) says true.
        let first = makeTransport()
        let link = connected(first)
        first.invalidate()
        clock.advance(by: registry.closeTimeout + 1)
        XCTAssertFalse(registry.isClosePending(address: "aa-bb-cc-dd-ee-ff"))

        events.removeAll()
        let second = makeTransport()
        second.connect()
        XCTAssertEqual(second.linkState, .connecting)
        XCTAssertEqual(link.count("CLCC"), 1, "probed, not adopted")
        XCTAssertFalse(events.contains(.linkStateChanged(.connected)))
        clock.advance(by: 3.1)
        XCTAssertEqual(second.linkState, .disconnecting, "no answer: closed")
    }

    func testPhoneStartedSetupAfterUserDisconnectIsTreatedAsClosing() async {
        // M2
        let transport = makeTransport()
        let link = connected(transport)
        transport.disconnect()
        dropped(transport, link)
        events.removeAll()

        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel)
        XCTAssertEqual(transport.linkState, .disconnecting)
        transport.handsFree(link, indicator: .callSetup(.incoming))
        XCTAssertFalse(events.contains(.indicator(.callSetup(.incoming))), "no call events reach the engine")
        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .disconnecting)
        await drainMainQueue()
        XCTAssertEqual(link.count("disconnect"), 2)
    }

    func testFreshSLCDuringAGivenUpSetupIsAdopted() {
        // M3(b): we closed our own timed-out attempt, but the link is still wanted.
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        clock.advance(by: 2) // retry: connect()
        clock.advance(by: 30) // no SLC: closeLink
        XCTAssertEqual(transport.linkState, .disconnecting)
        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .connected)
        clock.advance(by: 20)
        XCTAssertEqual(transport.linkState, .connected, "the disconnect timer was cancelled")
    }

    func testLateDisconnectedDuringSetupIsIgnoredForTheState() {
        // L1
        let transport = makeTransport()
        let link = connected(transport)
        dropped(transport, link)
        transport.sentLine("AT+BRSF=116", detail: nil, channel: link.channel)
        XCTAssertEqual(transport.linkState, .connecting)
        transport.handsFree(link, disconnectedWithStatus: 0) // late callback of the old link
        XCTAssertEqual(transport.linkState, .connecting)
        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .connected)
    }

    func testDeferredConnectIsDroppedWhenThePhonesSLCCameUp() async {
        // L2: the inherited close confirms inside a callback, so connect() is deferred.
        let first = makeTransport()
        let link = connected(first)
        first.invalidate()
        let second = makeTransport()
        second.connect()
        link.isConnected = false
        second.handsFree(link, disconnectedWithStatus: 0)
        XCTAssertEqual(second.linkState, .connecting)
        link.isConnected = true // the phone's own SLC completed before the deferred connect() ran
        await drainMainQueue()
        XCTAssertEqual(link.count("connect"), 1, "no connect() on an SLC that is already up")
    }

    func testWithoutTapAnyFinalResultAfterTheProbeAdopts() {
        // L4
        let transport = makeTransport(assumeOutgoingTap: false)
        let link = connected(transport)
        dropped(transport, link)
        link.isConnected = true
        clock.advance(by: 2) // retry finds the SLC up: probe
        XCTAssertEqual(link.count("CLCC"), 1)
        transport.receivedLine("OK", detail: nil) // AT+CLCC itself is invisible without the tap
        XCTAssertEqual(transport.linkState, .connected)
    }

    // MARK: Call history

    private var historyEvents: [TransportEvent] {
        events.filter { if case .callHistory = $0 { true } else { false } }
    }

    func testCallHoldNeedsThreeWayCallingAndReportsTheAnswer() throws {
        let transport = makeTransport()
        let link = connected(transport)
        XCTAssertFalse(transport.supportsCallHold)
        XCTAssertThrowsError(try transport.callHold(.holdActiveAcceptOther)) { XCTAssertEqual($0 as? TransportError, .unsupported) }
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("AT+CHLD") })

        link.audioGatewayFeatures = 0b1   // three-way calling
        link.callHoldModes = 0b1011       // CHLD 0, 1 and 2
        XCTAssertTrue(transport.supportsCallHold)
        try transport.callHold(.holdActiveAcceptOther)
        XCTAssertEqual(link.calls.last, "AT+CHLD=2")
        transport.sentLine("AT+CHLD=2", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertTrue(events.contains(.commandCompleted(.callHold, .ok)))
    }

    func testCallHoldSupportNeedsModesZeroOneAndTwo() {
        XCTAssertTrue(AppleHFPTransport.supportsCallHold(features: 0x3ef, holdModes: 0x7f))
        XCTAssertFalse(AppleHFPTransport.supportsCallHold(features: 0x3ee, holdModes: 0x7f), "no three-way calling bit")
        XCTAssertFalse(AppleHFPTransport.supportsCallHold(features: 0x1, holdModes: 0b0011), "mode 2 missing")
    }

    /// Regression (2026-10-30): `AT+CPBS` was never written after a failed write of IOBluetooth's own
    /// command, and the read waited for an answer forever (endless spinner in the dialer).
    func testUnansweredCallListReadIsGivenUp() throws {
        let transport = makeTransport()
        let link = connected(transport)
        clock.advance(by: 10)
        try transport.readCallHistory(.dialed, count: 2)
        try transport.readCallHistory(.missed, count: 2)
        XCTAssertEqual(link.calls.last, #"AT+CPBS="DC""#)
        clock.advance(by: 7)
        XCTAssertFalse(events.contains(.callHistoryUnanswered(.dialed)))
        clock.advance(by: 1)
        XCTAssertEqual(events.filter { if case .callHistoryUnanswered = $0 { true } else { false } },
                       [.callHistoryUnanswered(.dialed), .callHistoryUnanswered(.missed)])

        // A late answer to the given-up command is ignored; the next read starts cleanly.
        transport.sentLine(#"AT+CPBS="DC""#, detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertFalse(link.calls.contains("AT+CPBR=1,2"))
        try transport.readCallHistory(.received, count: 2)
        XCTAssertEqual(link.calls.last, #"AT+CPBS="RC""#)
    }

    // MARK: Review fixes (PR #7)

    func testCallHoldNeedsTheWriteHook() {
        let transport = makeTransport(address: "aa-bb-cc-dd-ee-02", assumeOutgoingTap: false)
        let link = connected(transport)
        link.audioGatewayFeatures = 0b1
        link.callHoldModes = 0b1011
        XCTAssertFalse(transport.supportsCallHold, "without the hook the phone's OK cannot be matched to AT+CHLD")
    }

    func testCallListReadGivesUpWhenTheLinkNeverBecomesIdle() throws {
        let transport = makeTransport()
        let link = connected(transport)
        try transport.readCallHistory(.dialed, count: 5)
        transport.sentLine("AT+VGS=7", detail: nil, channel: link.channel)   // never answered, silent link
        clock.advance(by: 17.5)
        XCTAssertFalse(events.contains(.callHistoryUnanswered(.dialed)))
        clock.advance(by: 1)
        XCTAssertTrue(events.contains(.callHistoryUnanswered(.dialed)), "the queued read is not left waiting forever")
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("AT+CPB") }, "IOBluetooth's safety gate is never bypassed")
    }

    func testDiscardedCallListCommandIsUnansweredNotRefused() throws {
        let transport = makeTransport()
        let link = connected(transport)
        clock.advance(by: 10)
        try transport.readCallHistory(.dialed, count: 5)
        transport.sentLine(#"AT+CPBS="DC""#, detail: nil, channel: link.channel)
        clock.advance(by: 6)
        transport.receivedLine("+CIEV: 5,3", detail: nil)   // an unrelated line: the tracker drops the stale command
        XCTAssertTrue(events.contains(.callHistoryUnanswered(.dialed)))
        XCTAssertFalse(events.contains(.callHistory(.dialed, nil)), "no answer is not a refusal")
    }

    func testCallHistoryIsSelectedThenReadOneListAtATime() async throws {
        let transport = makeTransport()
        let link = connected(transport)
        clock.advance(by: 10)
        try transport.readCallHistory(.dialed, count: 2)
        try transport.readCallHistory(.missed, count: 2)
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("AT+") }, [#"AT+CPBS="DC""#], "the second list waits for the first")

        transport.sentLine(#"AT+CPBS="DC""#, detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        await drainMainQueue()   // the follow-up command is deferred out of the callback
        XCTAssertEqual(link.calls.last, "AT+CPBR=1,2")

        transport.sentLine("AT+CPBR=1,2", detail: nil, channel: link.channel)
        transport.receivedLine(#"+CPBR: 1,"+49300000123",145,"Jane Doe""#, detail: nil)
        transport.receivedLine(#"+CPBR: 2,"+49300000456",145,"""#, detail: nil)
        transport.receivedLine("OK", detail: nil)
        await drainMainQueue()
        XCTAssertEqual(historyEvents, [.callHistory(.dialed, [
            CallHistoryEntry(number: "+49300000123", name: "Jane Doe"), CallHistoryEntry(number: "+49300000456"),
        ])])
        XCTAssertEqual(link.calls.last, #"AT+CPBS="MC""#)

        // The phone refuses the second list (no access to the call history).
        transport.sentLine(#"AT+CPBS="MC""#, detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        await drainMainQueue()
        transport.sentLine("AT+CPBR=1,2", detail: nil, channel: link.channel)
        transport.receivedLine("+CME ERROR: 3", detail: nil)
        XCTAssertEqual(historyEvents.last, .callHistory(.missed, nil))
    }

    /// Regression test for the crash of 2026-10-29 (SIGSEGV in `-[IOBluetoothHandsFreeDevice
    /// processResultCode:]`): a read interleaved with IOBluetooth's own commands right after the SLC.
    func testCallHistoryWaitsForTheQuietPeriodAndAnIdleLink() throws {
        let transport = makeTransport()
        let link = connected(transport)
        clock.advance(by: 2)
        try transport.readCallHistory(.dialed, count: 5)
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("AT+CPB") }, "not while IOBluetooth still finishes the set-up")

        // IOBluetooth's own command is still waiting for its reply when the quiet period ends.
        transport.sentLine("AT+VGS=7", detail: nil, channel: link.channel)
        clock.advance(by: 8)
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("AT+CPB") }, "not while another command waits for its reply")
        transport.receivedLine("OK", detail: nil)
        clock.advance(by: 0.5)
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("AT+CPB") }, [#"AT+CPBS="DC""#])
    }

    /// The read starts as soon as IOBluetooth's follow-up commands went out and were answered, instead
    /// of always waiting the full quiet period.
    func testCallHistoryStartsOnceIOBluetoothsFollowUpsAreAnswered() throws {
        let transport = makeTransport()
        let link = connected(transport)
        try transport.readCallHistory(.dialed, count: 5)
        transport.sentLine("AT+VGS=7", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        clock.advance(by: 0.5)
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("AT+CPB") }, "AT+VGM is still due")
        transport.sentLine("AT+VGM=7", detail: nil, channel: link.channel)
        clock.advance(by: 0.5)
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("AT+CPB") }, "AT+VGM waits for its reply")
        transport.receivedLine("OK", detail: nil)
        clock.advance(by: 0.5)
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("AT+CPB") }, [#"AT+CPBS="DC""#], "about 1.5 s after the link came up, not 10 s")
    }

    func testCallHistoryNeedsTheWriteHookAndALink() throws {
        let untapped = makeTransport(address: "aa-bb-cc-dd-ee-01", assumeOutgoingTap: false)
        _ = connected(untapped)
        XCTAssertThrowsError(try untapped.readCallHistory(.dialed, count: 5)) {
            XCTAssertEqual($0 as? TransportError, .unsupported)
        }
        let transport = makeTransport()
        XCTAssertThrowsError(try transport.readCallHistory(.dialed, count: 5)) {
            XCTAssertEqual($0 as? TransportError, .notConnected)
        }
    }

    func testLinkLossDropsQueuedCallHistoryReads() throws {
        let transport = makeTransport()
        let link = connected(transport)
        try transport.readCallHistory(.dialed, count: 5)
        try transport.readCallHistory(.received, count: 5)
        dropped(transport, link)
        clock.advance(by: 2)
        let again = made.last!
        again.isConnected = true
        transport.handsFree(again, connectedWithStatus: 0)
        try transport.readCallHistory(.missed, count: 5)
        clock.advance(by: 10)
        XCTAssertEqual(again.calls.filter { $0.hasPrefix("AT+CPBS") }.last, #"AT+CPBS="MC""#,
                       "a fresh link starts with the new request, not with the old queue")
    }
}
