import Foundation
import Observation

/// The call state machine: idle → ringing/dialing → active ⇄ held → ended → idle.
///
/// Driven only by `TransportEvent`s, so it behaves the same for every transport and in both modes
/// (remote control and audio on the Mac). The UI observes it and calls its commands.
///
/// HFP specifics handled here (Mac = HF, phone = AG):
/// - Without a headset connected to it, the Pixel sends neither `RING` nor `+CLIP`, only
///   `+CIEV callsetup=1` (with a headset it does send them). So the caller number is fetched with
///   `AT+CLCC` whenever a call appears with an unknown number (with a few retries); `+CLIP` is used
///   when it comes.
/// - The HFP spec orders `call=1` before `callsetup=0` when a call is answered, but some phones
///   send them the other way round. `callsetup=0` without `call=1` is therefore only treated as
///   "not answered" after a short grace period.
/// - Audio: when the phone opens SCO although audio on the Mac is off, the audio is handed straight
///   back (`transferAudioToPhone`). With audio on, the same hook is the per-call fallback.
@MainActor
@Observable
public final class CallEngine {
    public struct Configuration: Equatable, Sendable {
        /// How long `callsetup=0` may precede `call=1` before the call counts as not answered.
        public var setupEndGrace: TimeInterval = 0.5
        /// How long an ended call stays visible before the engine returns to idle.
        public var endedDisplayDuration: TimeInterval = 4
        /// An optimistic outgoing call fails if the phone does not start it within this time.
        public var dialTimeout: TimeInterval = 15
        /// Delay between call list requests while the number is still unknown.
        public var numberLookupRetryDelay: TimeInterval = 1
        /// Call list requests per call while the number is unknown.
        public var numberLookupAttempts = 3
        /// Audio on the Mac only: hand the audio back if SCO is not up this long after answering.
        public var audioSetupTimeout: TimeInterval = 5
        /// A call lost with the link is resumed (same ID, number, start time) if the link comes back
        /// within this window and the phone still reports a call.
        public var lostCallRestoreWindow: TimeInterval = 120

        public init() {}
    }

    // MARK: Observable state

    public private(set) var linkState: LinkState
    /// When the transport will try to reconnect next; nil = no attempt scheduled.
    public private(set) var nextReconnectAttempt: Date?
    /// The Bluetooth stack stopped confirming disconnects; reconnects may not work until Bluetooth
    /// is toggled or Pickup restarted (see `TransportEvent.linkSetupBlocked`).
    public private(set) var isLinkSetupBlocked = false
    public private(set) var deviceName: String?
    /// The current call, or the call that just ended (phase `.ended`) until it is cleared.
    public private(set) var call: CallInfo?
    /// A second incoming call while `call` is active (call waiting). Shown only; not controllable yet.
    public private(set) var waitingCall: CallInfo?
    public private(set) var indicators = HFPIndicators()
    public private(set) var audioRoute: AudioRoute = .phone
    /// Most recent time the engine moved the audio back to the phone, for a short notice.
    public private(set) var lastAudioFallback: AudioFallback?
    /// Most recent call command the phone rejected (accept, end, dial, DTMF).
    public private(set) var lastCommandFailure: CommandFailure?
    /// User setting "Take calls on this Mac". Off by default until the audio extension ships.
    public var takeCallsOnMac = false

    public var phase: CallPhase { call?.phase ?? .idle }
    public var supportsAudio: Bool { transport.supportsAudio }
    /// Audio on the Mac is possible for this call: transport capability and user setting.
    public var isAudioOnMacEnabled: Bool { supportsAudio && takeCallsOnMac }
    public var phoneStatus: PhoneStatus {
        PhoneStatus(
            hasService: indicators.service, signal: indicators.signal,
            isRoaming: indicators.roaming, battery: indicators.battery
        )
    }

    /// Called once for every call that reaches `.ended` (for notifications, e.g. missed calls).
    @ObservationIgnored public var onCallFinished: ((CallInfo) -> Void)?

    // MARK: Dependencies and bookkeeping

    @ObservationIgnored private let transport: HFPTransport
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private let log: DiagnosticLogging
    @ObservationIgnored public let configuration: Configuration

    /// The call the user ended on this Mac (decline, cancel, hang up), to pick the end reason.
    @ObservationIgnored private var localEndRequestedFor: UUID?
    /// An outgoing call created by `dial` that the phone has not confirmed with `callsetup` yet.
    @ObservationIgnored private var unconfirmedDialFor: UUID?
    @ObservationIgnored private var lookupAttempts = 0
    @ObservationIgnored private var recentlyLost: CallInfo?
    @ObservationIgnored private var expectingAudioClose = false
    /// A call list request was skipped because the SLC was not up yet.
    @ObservationIgnored private var callListWantedOnConnect = false
    /// The user cancelled this outgoing call. Survives a rejected `AT+CHUP`: if the phone starts the
    /// call anyway, the engine ends it again.
    @ObservationIgnored private var cancelRequestedFor: UUID?
    @ObservationIgnored private var cancelResentFor: UUID?
    @ObservationIgnored private var isInvalidated = false

    @ObservationIgnored private var setupEndTask: ScheduledTask?
    @ObservationIgnored private var endedClearTask: ScheduledTask?
    @ObservationIgnored private var dialTimeoutTask: ScheduledTask?
    @ObservationIgnored private var lookupRetryTask: ScheduledTask?
    @ObservationIgnored private var audioWatchdogTask: ScheduledTask?

    public init(
        transport: HFPTransport,
        scheduler: Scheduler? = nil,
        log: DiagnosticLogging = NullDiagnosticLog(),
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.log = log
        self.configuration = configuration
        self.linkState = transport.linkState
        self.deviceName = transport.deviceName
        transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: Lifecycle

    /// Opens the link and keeps it up (auto-reconnect).
    public func start() {
        log.log(.command, "engine start -> transport.connect()")
        transport.connect()
    }

    /// Closes the link; no auto-reconnect until `start()` or `reconnect()`.
    public func stop() {
        log.log(.command, "engine stop -> transport.disconnect()")
        transport.disconnect()
    }

    /// Reconnect now (explicit user request; also after `stop()`).
    public func reconnect() {
        log.log(.command, "reconnect -> transport.reconnect()")
        transport.reconnect()
    }

    /// Shuts the engine and its transport down for good, e.g. before switching to another phone.
    /// Must be called before the engine (and so the transport) is released. Afterwards every
    /// command throws `.notConnected`.
    public func invalidate() {
        guard !isInvalidated else { return }
        log.log(.command, "engine invalidate -> transport.invalidate()")
        isInvalidated = true
        transport.invalidate()
        transport.eventHandler = nil
        linkStateChanged(.disconnected)
        for task in [setupEndTask, endedClearTask, dialTimeoutTask, lookupRetryTask, audioWatchdogTask] {
            task?.cancel()
        }
    }

    /// Wire to `NSWorkspace.willSleepNotification`.
    public func prepareForSleep() {
        log.log(.command, "system will sleep -> transport.prepareForSleep()")
        transport.prepareForSleep()
    }

    /// Wire to `NSWorkspace.didWakeNotification`. Reconnects only if the link was wanted before
    /// sleep; after `stop()` the phone stays disconnected.
    public func systemDidWake() {
        log.log(.command, "system did wake -> transport.resumeAfterSleep()")
        transport.resumeAfterSleep()
    }

    // MARK: Call commands

    /// Answers the ringing call. Remote-control mode: the audio stays on the phone.
    public func accept() throws {
        try requireConnected()
        guard phase == .ringing else { throw CallEngineError.invalidPhase(phase) }
        // Audio on the Mac (phase 4) will answer with audio here. Until then every answer keeps
        // the audio on the phone, whatever the setting says.
        log.log(.command, "accept -> acceptCallOnPhone()")
        try perform { try transport.acceptCallOnPhone() }
    }

    /// Rejects the ringing call.
    public func decline() throws {
        try requireConnected()
        guard phase == .ringing, let call else { throw CallEngineError.invalidPhase(phase) }
        log.log(.command, "decline -> endCall()")
        localEndRequestedFor = call.id
        try perform { try transport.endCall() }
    }

    /// Ends the active or held call, or cancels the outgoing call.
    public func hangUp() throws {
        try requireConnected()
        guard [.dialing, .active, .held].contains(phase), let call else {
            throw CallEngineError.invalidPhase(phase)
        }
        log.log(.command, "hang up -> endCall()")
        localEndRequestedFor = call.id
        if phase == .dialing {
            cancelRequestedFor = call.id
        }
        try perform { try transport.endCall() }
    }

    /// Declines when ringing, hangs up otherwise.
    public func endCall() throws {
        if phase == .ringing {
            try decline()
        } else {
            try hangUp()
        }
    }

    /// Places an outgoing call. The engine shows it as dialing right away; it fails if the phone
    /// rejects the command or does not start the call within `dialTimeout`.
    ///
    /// MMI/USSD codes (`DialNumber.isServiceCode`, e.g. `**21*...#` call forwarding) are refused
    /// unless `allowServiceCode` is true: pass true only for input typed on the dial pad or after
    /// the user explicitly confirmed a code that came from a link.
    public func dial(_ number: DialNumber, allowServiceCode: Bool = false) throws {
        try requireConnected()
        guard !phase.isLive else { throw CallEngineError.callInProgress }
        guard allowServiceCode || !number.isServiceCode else {
            log.log(.warning, "refused to dial a service code without confirmation")
            throw CallEngineError.serviceCodeNeedsConfirmation
        }
        log.log(.command, "dial \(number) -> dial()")
        try perform { try transport.dial(number) }
        let call = startCall(direction: .outgoing, phase: .dialing, callerID: .number(number.value))
        unconfirmedDialFor = call.id
        dialTimeoutTask = scheduler.schedule(after: configuration.dialTimeout) { [weak self] in
            guard let self, self.unconfirmedDialFor == call.id, self.call?.id == call.id else { return }
            if self.cancelRequestedFor == call.id {
                self.finish(.cancelled)
            } else {
                self.log.log(.warning, "phone did not start the outgoing call within \(self.configuration.dialTimeout) s")
                self.finish(.failed)
            }
        }
    }

    /// Sends one DTMF tone. Note: with the Pixel the remote party does not hear it (phase 0).
    public func sendDTMF(_ digit: DTMFDigit) throws {
        try requireConnected()
        guard phase == .active else { throw CallEngineError.invalidPhase(phase) }
        // The digit is not logged: DTMF often carries PINs.
        log.log(.command, "dtmf -> sendDTMF()")
        try perform { try transport.sendDTMF(digit) }
    }

    /// "Move to phone": hands the call audio back to the phone.
    public func transferAudioToPhone() throws {
        try requireConnected()
        handBackAudioToPhone(.userRequest)
    }

    /// Asks the phone for the current call list again (refreshes the number).
    public func refreshCallList() {
        requestCallList(resetAttempts: true)
    }

    /// Per-call fallback: move the audio to the phone and leave a notice. The call continues in
    /// remote-control mode. Safe to call in any mode and phase. Returns false if the transport
    /// could not send the request (it is retried when the link comes up).
    @discardableResult
    public func handBackAudioToPhone(_ reason: AudioFallbackReason) -> Bool {
        log.log(.command, "hand audio back to phone (\(reason.rawValue)) -> transferAudioToPhone()")
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        do {
            try transport.transferAudioToPhone()
        } catch {
            log.log(.error, "transferAudioToPhone failed: \(error)")
            return false
        }
        expectingAudioClose = true
        lastAudioFallback = AudioFallback(reason: reason, date: scheduler.now, callID: call?.id)
        return true
    }

    // MARK: Event handling

    func handle(_ event: TransportEvent) {
        log.log(.state, "event \(event)")
        if linkState == .disconnected || linkState == .disconnecting {
            switch event {
            case .indicator, .ring, .callerID, .callWaiting, .currentCalls:
                // Belongs to an SLC nobody wants (e.g. completing during a disconnect).
                log.log(.state, "ignored: link is \(linkState.rawValue)")
                return
            default:
                break
            }
        }
        switch event {
        case .linkStateChanged(let state):
            linkStateChanged(state)
        case .reconnectScheduled(let date):
            nextReconnectAttempt = date
        case .linkSetupBlocked(let blocked):
            isLinkSetupBlocked = blocked
        case .indicator(let indicator):
            indicatorChanged(indicator)
        case .ring:
            break // The callsetup indicator drives the state; RING only repeats it.
        case .callerID(let number):
            callerIDReceived(CallerID(listedNumber: number))
        case .callWaiting(let number):
            callWaitingReceived(CallerID(listedNumber: number))
        case .currentCalls(let calls):
            currentCallsReceived(calls)
        case .commandCompleted(let command, let result):
            commandCompleted(command, result)
        case .audioConnectionChanged(let isOpen):
            audioConnectionChanged(isOpen: isOpen)
        }
    }

    private func linkStateChanged(_ state: LinkState) {
        let old = linkState
        linkState = state
        deviceName = transport.deviceName
        guard state != old else { return }

        if state == .connected {
            nextReconnectAttempt = nil
            if callListWantedOnConnect, phase.isLive {
                requestCallList(resetAttempts: true)
            }
            callListWantedOnConnect = false
            // SCO opened during the SLC set-up and could not be handed back then.
            if audioRoute == .mac, !isAudioOnMacEnabled {
                handBackAudioToPhone(.audioOnMacDisabled)
            }
            return
        }
        // Indicators belong to one SLC; the next one reports them afresh.
        indicators = HFPIndicators()
        waitingCall = nil
        audioRoute = .phone
        // A hand-back deferred by the transport is dropped when the link goes down.
        expectingAudioClose = false
        if phase.isLive {
            finish(.connectionLost)
        }
    }

    private func indicatorChanged(_ indicator: HFPIndicator) {
        guard indicators.apply(indicator) else { return }
        switch indicator {
        case .call(let isActive):
            if isActive { callIndicatorSet() } else { callIndicatorCleared() }
        case .callSetup(let setup):
            callSetupChanged(setup)
        case .callHeld(let held):
            callHeldChanged(held)
        case .service, .signal, .roaming, .battery:
            break
        }
    }

    private func callSetupChanged(_ setup: CallSetupState) {
        switch setup {
        case .incoming:
            if phase == .active || phase == .held {
                if waitingCall == nil {
                    waitingCall = CallInfo(direction: .incoming, callerID: .unknown, phase: .ringing, startedAt: scheduler.now)
                    log.log(.state, "call waiting")
                }
                requestCallList(resetAttempts: true)
            } else if phase != .ringing {
                startCall(direction: .incoming, phase: .ringing, callerID: .unknown)
                requestCallList(resetAttempts: true)
            }

        case .outgoing, .remoteAlerting:
            if phase == .dialing, var call {
                unconfirmedDialFor = nil
                dialTimeoutTask?.cancel()
                dialTimeoutTask = nil
                call.isRemoteAlerting = setup == .remoteAlerting
                self.call = call
                endAgainIfCancelled(call.id)
            } else if phase == .active || phase == .held {
                log.log(.warning, "second outgoing call during a call (three-way calling) is not tracked")
            } else {
                // Dialed on the phone itself.
                var call = startCall(direction: .outgoing, phase: .dialing, callerID: .unknown)
                call.isRemoteAlerting = setup == .remoteAlerting
                self.call = call
                requestCallList(resetAttempts: true)
            }

        case .none:
            if waitingCall != nil, phase == .active || phase == .held {
                log.log(.state, "waiting call gone")
                waitingCall = nil
                // If the waiting call was taken (calls swapped), the list shows the new active call.
                requestCallList(resetAttempts: true)
            } else if phase == .ringing || phase == .dialing, indicators.call != true, let call {
                setupEndTask?.cancel()
                setupEndTask = scheduler.schedule(after: configuration.setupEndGrace) { [weak self] in
                    self?.setupEndedWithoutAnswer(call.id)
                }
            }
        }
    }

    private func setupEndedWithoutAnswer(_ id: UUID) {
        setupEndTask = nil
        guard let call, call.id == id, indicators.call != true else { return }
        let local = localEndRequestedFor == id
        switch call.phase {
        case .ringing: finish(local ? .declined : .missed)
        case .dialing: finish(local || cancelRequestedFor == id ? .cancelled : .unanswered)
        default: break
        }
    }

    private func callIndicatorSet() {
        setupEndTask?.cancel()
        setupEndTask = nil
        if var call, call.phase == .ringing || call.phase == .dialing {
            unconfirmedDialFor = nil
            dialTimeoutTask?.cancel()
            dialTimeoutTask = nil
            call.isRemoteAlerting = false
            call.connectedAt = scheduler.now
            transition(&call, to: .active)
            self.call = call
            if call.callerID == .unknown {
                requestCallList(resetAttempts: true)
            }
            startAudioWatchdog()
            endAgainIfCancelled(call.id)
        } else if !phase.isLive {
            // The call was already running: the link came up mid-call, or the call was set up
            // and answered before we saw the set-up.
            adoptRunningCall()
            // Always refresh: a resumed call may have been replaced on the phone meanwhile.
            requestCallList(resetAttempts: true)
        }
    }

    private func callIndicatorCleared() {
        guard let call, call.phase == .active || call.phase == .held else { return }
        let waiting = waitingCall
        finish(localEndRequestedFor == call.id ? .hungUp : .remoteEnded)
        // HFP: when the active call ends while another one waits, the waiting call keeps ringing.
        if let waiting, indicators.callSetup == .incoming {
            let promoted = startCall(direction: .incoming, phase: .ringing, callerID: waiting.callerID)
            if promoted.callerID == .unknown {
                requestCallList(resetAttempts: true)
            }
        }
    }

    private func callHeldChanged(_ held: CallHeldState) {
        guard var call, call.phase == .active || call.phase == .held else { return }
        switch held {
        case .heldOnly:
            transition(&call, to: .held)
        case .none, .activeAndHeld:
            transition(&call, to: .active)
        }
        self.call = call
    }

    private func callerIDReceived(_ callerID: CallerID) {
        if waitingCall != nil, phase == .active || phase == .held {
            waitingCall?.callerID = callerID
        } else if var call, call.phase == .ringing {
            call.callerID = merged(call.callerID, with: callerID)
            self.call = call
        }
    }

    private func callWaitingReceived(_ callerID: CallerID) {
        guard phase == .active || phase == .held else { return }
        if waitingCall == nil {
            waitingCall = CallInfo(direction: .incoming, callerID: callerID, phase: .ringing, startedAt: scheduler.now)
        } else {
            waitingCall?.callerID = callerID
        }
    }

    private func currentCallsReceived(_ calls: [HFPCall]) {
        lookupRetryTask?.cancel()
        lookupRetryTask = nil

        if var waiting = waitingCall, let entry = calls.first(where: { $0.status == .waiting }) {
            waiting.callerID = merged(waiting.callerID, with: CallerID(listedNumber: entry.number))
            waitingCall = waiting
        }

        guard var call, call.phase.isLive else { return }
        if let entry = Self.entry(in: calls, matching: call) {
            let listed = CallerID(listedNumber: entry.number)
            if listed == .withheld, call.callerID == .unknown,
               lookupAttempts < configuration.numberLookupAttempts {
                // Android sometimes lists a fresh call before its number is known: ask again
                // before concluding the number is withheld.
                if call.direction == .unknown {
                    call.direction = entry.direction
                    self.call = call
                }
                scheduleLookupRetry()
                return
            }
            call.callerID = merged(call.callerID, with: listed)
            if call.direction == .unknown {
                call.direction = entry.direction
            }
            self.call = call
        } else if call.callerID == .unknown {
            log.log(.warning, "call list has no entry for the \(call.phase.rawValue) call (\(calls.count) entries)")
            scheduleLookupRetry()
        }
    }

    private func commandCompleted(_ command: HFPCommand, _ result: CommandResult) {
        guard !result.isSuccess else { return }
        switch command {
        case .dial:
            lastCommandFailure = CommandFailure(command: command, result: result, date: scheduler.now)
            if let id = unconfirmedDialFor, call?.id == id {
                log.log(.warning, "phone rejected the dial command: \(result)")
                finish(.failed)
            }
        case .accept, .endCall, .dtmf:
            lastCommandFailure = CommandFailure(command: command, result: result, date: scheduler.now)
            if command == .endCall {
                localEndRequestedFor = nil
            }
        case .currentCalls:
            if call?.callerID == .unknown, call?.phase.isLive == true {
                scheduleLookupRetry()
            }
        case .other:
            break // Commands IOBluetooth sends on its own (SMS probing etc.) fail routinely.
        }
    }

    private func audioConnectionChanged(isOpen: Bool) {
        if isOpen {
            // The transport re-reports an open SCO after the SLC is up; a hand-back may be under way.
            let handBackPending = audioRoute == .mac && expectingAudioClose
            audioRoute = .mac
            audioWatchdogTask?.cancel()
            audioWatchdogTask = nil
            if !isAudioOnMacEnabled, !handBackPending {
                // Remote-control mode: the phone opened SCO on its own; the conversation belongs on the phone.
                handBackAudioToPhone(.audioOnMacDisabled)
            }
        } else {
            let wasOnMac = audioRoute == .mac
            audioRoute = .phone
            if wasOnMac, !expectingAudioClose, isAudioOnMacEnabled, phase == .active || phase == .held {
                lastAudioFallback = AudioFallback(reason: .audioDropped, date: scheduler.now, callID: call?.id)
                log.log(.warning, "audio link dropped during the call; audio is on the phone now")
            }
            expectingAudioClose = false
        }
    }

    // MARK: Helpers

    /// Starts a new call, finalising any call still waiting for its set-up grace period.
    @discardableResult
    private func startCall(direction: CallDirection, phase: CallPhase, callerID: CallerID) -> CallInfo {
        if let pending = setupEndTask, let current = call {
            pending.cancel()
            setupEndTask = nil
            setupEndedWithoutAnswer(current.id)
        }
        if let current = call, current.phase.isLive {
            // Should not happen with a consistent AG; never drop a live call silently.
            log.log(.warning, "new call while the \(current.phase.rawValue) call is still live; ending it")
            switch current.phase {
            case .ringing: finish(.missed)
            case .dialing: finish(.unanswered)
            default: finish(.remoteEnded)
            }
        }
        endedClearTask?.cancel()
        endedClearTask = nil
        lookupRetryTask?.cancel()
        lookupRetryTask = nil
        lookupAttempts = 0
        localEndRequestedFor = nil
        unconfirmedDialFor = nil
        recentlyLost = nil

        let call = CallInfo(direction: direction, callerID: callerID, phase: phase, startedAt: scheduler.now)
        log.log(.state, "call \(call.id.uuidString.prefix(8)) \(direction.rawValue) -> \(phase.rawValue)")
        self.call = call
        return call
    }

    /// A call already running when the link came up. If the link dropped during a call shortly
    /// before, it is the same call: keep its identity, number and start time.
    @discardableResult
    private func adoptRunningCall() -> CallInfo {
        if let lost = recentlyLost, let lostAt = lost.endedAt,
           scheduler.now.timeIntervalSince(lostAt) <= configuration.lostCallRestoreWindow,
           lost.connectedAt != nil {
            endedClearTask?.cancel()
            endedClearTask = nil
            lookupRetryTask?.cancel()
            lookupRetryTask = nil
            lookupAttempts = 0
            recentlyLost = nil
            var call = lost
            call.phase = .active
            call.endedAt = nil
            call.endReason = nil
            log.log(.state, "call \(call.id.uuidString.prefix(8)) resumed after the link came back -> active")
            self.call = call
            return call
        }
        var call = startCall(direction: .unknown, phase: .active, callerID: .unknown)
        call.connectedAt = scheduler.now
        call.connectedAtIsApproximate = true
        self.call = call
        return call
    }

    private func transition(_ call: inout CallInfo, to phase: CallPhase) {
        guard call.phase != phase else { return }
        log.log(.state, "call \(call.id.uuidString.prefix(8)) \(call.phase.rawValue) -> \(phase.rawValue)")
        call.phase = phase
    }

    private func finish(_ reason: CallEndReason) {
        guard var call, call.phase.isLive else { return }
        for task in [setupEndTask, dialTimeoutTask, lookupRetryTask, audioWatchdogTask] {
            task?.cancel()
        }
        setupEndTask = nil
        dialTimeoutTask = nil
        lookupRetryTask = nil
        audioWatchdogTask = nil
        localEndRequestedFor = nil
        unconfirmedDialFor = nil
        cancelRequestedFor = nil
        cancelResentFor = nil
        waitingCall = nil

        transition(&call, to: .ended)
        call.isRemoteAlerting = false
        call.endedAt = scheduler.now
        call.endReason = reason
        log.log(.state, "call \(call.id.uuidString.prefix(8)) ended: \(reason.rawValue)")
        self.call = call
        recentlyLost = reason == .connectionLost ? call : nil

        let id = call.id
        endedClearTask = scheduler.schedule(after: configuration.endedDisplayDuration) { [weak self] in
            guard let self, self.call?.id == id, self.phase == .ended else { return }
            self.call = nil
            self.log.log(.state, "idle")
        }
        onCallFinished?(call)
    }

    /// Keeps a known number when the list has none (e.g. the number we dialed).
    private func merged(_ current: CallerID, with new: CallerID) -> CallerID {
        if case .number = current, new == .withheld { return current }
        return new
    }

    /// The call list entry that describes `call`, by status; a single entry always matches.
    static func entry(in calls: [HFPCall], matching call: CallInfo) -> HFPCall? {
        let statuses: [CallListStatus]
        switch call.phase {
        case .ringing: statuses = [.incoming, .waiting]
        case .dialing: statuses = [.alerting, .dialing]
        case .active: statuses = [.active]
        case .held: statuses = [.held, .heldByResponseAndHold]
        case .idle, .ended: statuses = []
        }
        for status in statuses {
            if let entry = calls.first(where: { $0.status == status }) { return entry }
        }
        return calls.count == 1 ? calls[0] : nil
    }

    private func requestCallList(resetAttempts: Bool) {
        if resetAttempts { lookupAttempts = 0 }
        guard linkState == .connected else {
            // Indicators arrive during the SLC set-up, before commands are possible.
            callListWantedOnConnect = true
            return
        }
        lookupAttempts += 1
        do {
            try transport.requestCurrentCalls()
        } catch {
            log.log(.warning, "requestCurrentCalls failed: \(error)")
        }
    }

    private func scheduleLookupRetry() {
        guard lookupRetryTask == nil, lookupAttempts < configuration.numberLookupAttempts else { return }
        let id = call?.id
        lookupRetryTask = scheduler.schedule(after: configuration.numberLookupRetryDelay) { [weak self] in
            guard let self else { return }
            self.lookupRetryTask = nil
            guard self.call?.id == id, self.phase.isLive, self.call?.callerID == .unknown else { return }
            self.requestCallList(resetAttempts: false)
        }
    }

    private func startAudioWatchdog() {
        guard isAudioOnMacEnabled else { return }
        audioWatchdogTask?.cancel()
        audioWatchdogTask = scheduler.schedule(after: configuration.audioSetupTimeout) { [weak self] in
            guard let self else { return }
            self.audioWatchdogTask = nil
            if self.audioRoute != .mac, self.phase == .active {
                self.handBackAudioToPhone(.audioSetupTimedOut)
            }
        }
    }

    /// The user cancelled this outgoing call but the phone started it anyway (e.g. its `AT+CHUP`
    /// was rejected while the call was not set up yet): end it again, once.
    private func endAgainIfCancelled(_ id: UUID) {
        guard cancelRequestedFor == id, cancelResentFor != id else { return }
        cancelResentFor = id
        localEndRequestedFor = id
        log.log(.command, "outgoing call was cancelled on the Mac; ending it again -> endCall()")
        do {
            try transport.endCall()
        } catch {
            log.log(.error, "endCall failed: \(error)")
        }
    }

    private func requireConnected() throws {
        guard !isInvalidated, linkState == .connected else { throw CallEngineError.notConnected }
    }

    private func perform(_ command: () throws -> Void) throws {
        do {
            try command()
        } catch TransportError.notConnected {
            throw CallEngineError.notConnected
        } catch TransportError.unsupported {
            throw CallEngineError.unsupported
        } catch TransportError.invalidated {
            throw CallEngineError.notConnected
        }
    }
}
