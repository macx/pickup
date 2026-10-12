#if PICKUP_TESTING
import Foundation
import PickupCore

/// Clock for scenario runs: every delay is multiplied by `scale`, so grace periods and display times
/// pass quickly (`-PickupTestFastClock YES`, `-PickupTestClockScale <0...1>`, default 0.25).
@MainActor
final class FastScheduler: Scheduler {
    private let base = MainQueueScheduler()
    private let scale: Double
    init(scale: Double) { self.scale = scale }
    var now: Date { base.now }
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        base.schedule(after: delay * scale, action)
    }
}

/// A Pixel-like phone as an `HFPTransport`: no Bluetooth, fully scripted. It behaves like the phone in
/// recorded sessions with a real Pixel (indicators only, the number comes from `AT+CLCC`) and reacts to the app's
/// commands (accept, hang up, dial) the way a real phone would. All numbers and names are invented.
@MainActor
final class ScriptedTransport: HFPTransport {
    static let jane = "+491700000123"
    static let john = "+491710000456"

    let supportsAudio = false
    private(set) var linkState: LinkState = .disconnected
    let deviceName: String? = "Test Phone"
    var eventHandler: ((TransportEvent) -> Void)?
    /// What `AT+CLCC` currently returns.
    private(set) var callList: [HFPCall] = []
    private var isInvalidated = false

    // MARK: HFPTransport

    func connect() { bringUp() }
    func disconnect() { emit(.linkStateChanged(.disconnected)) }
    func reconnect() { bringUp() }
    func prepareForSleep() { disconnect() }
    func resumeAfterSleep() { bringUp() }
    func invalidate() { isInvalidated = true }

    func acceptCallOnPhone() throws {
        try requireLink()
        later { [self] in
            emit(.commandCompleted(.accept, .ok))
            answered()
        }
    }

    func endCall() throws {
        try requireLink()
        later { [self] in
            emit(.commandCompleted(.endCall, .ok))
            if callList.first?.status == .incoming || callList.first?.status == .dialing || callList.first?.status == .alerting {
                callList = []
                emit(.callSetup(.none))        // rejected / cancelled
            } else {
                remoteHangsUp()
            }
        }
    }

    func dial(_ number: DialNumber) throws {
        try requireLink()
        later { [self] in startOutgoing(number: number.value) }
    }

    func sendDTMF(_ digit: DTMFDigit) throws {
        try requireLink()
        later { [self] in emit(.commandCompleted(.dtmf, .ok)) }
    }

    func transferAudioToPhone() throws {}

    func requestCurrentCalls() throws {
        try requireLink()
        later { [self] in
            emit(.currentCalls(callList))
            emit(.commandCompleted(.currentCalls, .ok))
        }
    }

    // MARK: Phone side (driven by the scenario)

    func ringIncoming(number: String?) {
        callList = [HFPCall(index: 1, direction: .incoming, status: .incoming, number: number, numberType: 145)]
        emit(.callSetup(.incoming))
    }

    func answered() {
        callList = callList.map { var call = $0; call.status = .active; return call }
        emit(.call(true))
        emit(.callSetup(.none))
    }

    func setupEnded() { callList = []; emit(.callSetup(.none)) }
    func remoteHangsUp() {
        // A waiting caller keeps ringing when the active call ends (HFP): it becomes the incoming call.
        if var waiting = callList.first(where: { $0.status == .waiting }) {
            waiting.index = 1
            waiting.status = .incoming
            callList = [waiting]
        } else {
            callList = []
        }
        emit(.call(false))
    }
    func remoteAlerting() { emit(.callSetup(.remoteAlerting)) }
    func busy() {
        callList = []
        emit(.commandCompleted(.dial, .callFailure("BUSY")))
        emit(.callSetup(.none))
    }
    /// A second caller while a call is active. Like a real Pixel: `callsetup=1` and `+CCWA`, and the
    /// call list shows the waiting entry (`AT+CLCC` is requested when `callsetup=1` arrives).
    func callWaiting(number: String) {
        callList.append(HFPCall(index: 2, direction: .incoming, status: .waiting, number: number, numberType: 145))
        emit(.callSetup(.incoming))
        emit(.callWaiting(number))
    }
    func dropLink() { emit(.linkStateChanged(.disconnected)) }
    /// The link comes back while a call is still running (resume after link loss).
    func resumeLink() { bringUp(callActive: callList.first?.status == .active) }

    func startOutgoing(number: String) {
        callList = [HFPCall(index: 1, direction: .outgoing, status: .dialing, number: number, numberType: 145)]
        emit(.commandCompleted(.dial, .ok))
        emit(.callSetup(.outgoing))
    }

    // MARK: Internals

    private func bringUp(callActive: Bool = false) {
        guard !isInvalidated else { return }
        emit(.linkStateChanged(.connecting))
        emit(.call(callActive))
        emit(.callSetup(.none))
        emit(.service(true))
        emit(.signal(5))
        emit(.roaming(false))
        emit(.battery(4))
        emit(.linkStateChanged(.connected))
    }

    private func emit(_ indicator: HFPIndicator) { emit(.indicator(indicator)) }

    private func emit(_ event: TransportEvent) {
        if case .linkStateChanged(let state) = event { linkState = state }
        eventHandler?(event)
    }

    private func requireLink() throws {
        guard !isInvalidated else { throw TransportError.invalidated }
        guard linkState == .connected else { throw TransportError.notConnected }
    }

    /// Replies arrive on a later run-loop turn, like a real phone's.
    private func later(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
#endif
