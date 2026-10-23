import AppKit
import Observation
import PickupBluetooth
import PickupCore
import SwiftUI

/// Observable state the call panels render. `AppModel` maps the `CallEngine` onto it in one
/// place (`apply()`); views never see core or Bluetooth types.
@MainActor
@Observable
final class CallUIModel {
    var incoming: IncomingCallInfo?
    var active: ActiveCallInfo?
    var actions = CallActions()
    /// The incoming-call banner or the call HUD has keyboard focus (is the key window), so its keyboard
    /// shortcuts act and the primary button (Accept, End Call) has keyboard focus.
    var bannerHasFocus = false
    var hudHasFocus = false
    /// Set when the user places a call from Pickup: the call HUD takes keyboard focus once it is shown,
    /// so Return can end the call right away. Calls started on the phone and incoming calls never take focus.
    var focusHUDWhenShown = false
}

/// Owns the transport and the engine, binds them to the UI models and routes system events
/// (sleep/wake, `tel:` links, missed-call notifications).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Guidance: Equatable {
        case choosePhone
        case bluetoothDenied
        /// The phone is unreachable for a while: Bluetooth off/out of range, or the "Phone calls"
        /// grant on the Pixel was not given.
        case cannotConnect(phoneName: String?)
        /// First-run hint: another app still opens tel: links.
        case makeDefaultForLinks
    }

    // MARK: State for the UI

    private(set) var connection: ConnectionStatus = .noPhone
    private(set) var guidance: Guidance?
    private(set) var callIsLive = false
    private(set) var notice: String?
    private(set) var selectedAddress: String?
    private(set) var selectedName: String?

    let callUI = CallUIModel()
    let contacts = ContactsDirectory()
    let permissions = PermissionsModel()
    let linkHandler = LinkHandlerStatus()
    @ObservationIgnored private(set) lazy var panels = CallPanelController(model: callUI) { [weak self] in
        self?.log.log(.info, $0)
    }

    var canDial: Bool { (connection.isConnected || isDemo) && !callIsLive }

    // MARK: Internals

    static let addressKey = "phoneAddress"
    static let nameKey = "phoneName"
    /// Launch argument `-PickupDemo <incoming|call|remote|menu>`: static preview data, no Bluetooth.
    let isDemo = UserDefaults.standard.string(forKey: "PickupDemo") != nil

    @ObservationIgnored private var engine: CallEngine?
    @ObservationIgnored private lazy var log: DiagnosticLog = {
        #if PICKUP_TESTING
        if TestMode.isActive { return DiagnosticLog(directory: TestHarness.logDirectory) }
        #endif
        return DiagnosticLog()
    }()
    @ObservationIgnored private var dismissedCallID: UUID?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var stuckTask: Task<Void, Never>?
    @ObservationIgnored private var showCannotConnect = false
    @ObservationIgnored private var seenFailureDate: Date?
    @ObservationIgnored private var seenFallbackDate: Date?
    @ObservationIgnored private var lastHandledURL: (url: URL, date: Date)?

    private init() {
        guard !TestMode.isActive else { return }   // tests never read the user's real phone selection
        let defaults = UserDefaults.standard
        selectedAddress = defaults.string(forKey: Self.addressKey)
        selectedName = defaults.string(forKey: Self.nameKey)
    }

    // MARK: Lifecycle

    func start() {
        _ = panels
        if !TestMode.isActive { MissedCallNotifier.shared.install() }
        contacts.reload()
        if contacts.demoAccess == "yes" { contacts.loadDemo() }
        linkHandler.refresh()
        Task { await permissions.refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.permissions.refresh()
                self?.linkHandler.refresh()
                self?.contacts.loadIfNeeded()
                self?.apply()
            }
        }
        #if PICKUP_TESTING
        if TestMode.isActive { startTestScenario(); return }
        #endif
        if isDemo { apply(); return }
        requestPermissionsAfterLaunch()
        if let address = selectedAddress { makeEngine(address: address) } else { apply() }
    }

    /// Settings: choose (or clear) the phone. Re-creates transport and engine.
    func selectPhone(address: String?, name: String?) {
        if !TestMode.isActive {
            let defaults = UserDefaults.standard
            defaults.set(address, forKey: Self.addressKey)
            defaults.set(name, forKey: Self.nameKey)
        }
        selectedAddress = address
        selectedName = name
        teardown()
        if let address, !isDemo { makeEngine(address: address) } else { apply() }
    }

    func reconnect() { engine?.reconnect() }

    /// App termination: release the transport cleanly.
    func shutdown() { teardown() }

    func prepareForSleep() { engine?.prepareForSleep() }
    func systemDidWake() { engine?.systemDidWake() }

    private func makeEngine(address: String) {
        let transport = AppleHFPTransport(deviceAddress: address, log: log)
        let engine = CallEngine(transport: transport, log: log)
        engine.onCallFinished = { [weak self] call in self?.callFinished(call) }
        self.engine = engine
        callUI.actions = makeActions()
        observe(engine)
        engine.start()
    }

    #if PICKUP_TESTING
    /// `-PickupTestScenario <name>`: the scripted phone replaces Bluetooth (see `TestHarness`).
    private func startTestScenario() {
        let harness = TestHarness.shared
        selectedAddress = "test-phone"
        selectedName = "Test Phone"
        if harness.scenario == .stressCycle {
            // The stress cycle drives the call UI models directly; no engine, or it would overwrite them.
            apply()
            harness.begin()
            return
        }
        let engine = CallEngine(transport: harness.transport, scheduler: harness.scheduler, log: log)
        engine.onCallFinished = { [weak self] call in self?.callFinished(call) }
        self.engine = engine
        callUI.actions = makeActions()
        observe(engine)
        engine.start()
        harness.begin()
    }
    #endif

    private func teardown() {
        engine?.onCallFinished = nil
        engine?.stop()
        engine?.invalidate()   // every later command on the old engine throws .notConnected
        engine = nil
        stuckTask?.cancel()
        stuckTask = nil
        showCannotConnect = false
        dismissedCallID = nil
    }

    // MARK: Engine -> UI binding

    private func observe(_ engine: CallEngine) {
        withObservationTracking {
            apply()
        } onChange: { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.observe(engine)
            }
        }
    }

    /// Reads every piece of engine state the UI needs (so the observation tracks it) and
    /// publishes plain values. Called inside `withObservationTracking`.
    private func apply() {
        let bluetoothDenied = permissions.bluetoothDenied
        let linkHint: Guidance? = linkHandler.shouldShowHint && !isDemo ? .makeDefaultForLinks : nil
        _ = notice // tracked, so the call windows show notices
        guard let engine else {
            set(\.connection, selectedAddress == nil ? .noPhone : .disconnected(phoneName: selectedName ?? fallbackPhoneName))
            set(\.callIsLive, false)
            set(\.guidance, bluetoothDenied ? .bluetoothDenied : (selectedAddress == nil ? .choosePhone : linkHint))
            if !isDemo { setUI(incoming: nil, active: nil) }
            return
        }
        let phoneName = engine.deviceName ?? selectedName ?? fallbackPhoneName

        // Connection.
        let link = engine.linkState
        let status: ConnectionStatus = switch link {
        case .connected: .connected(phoneName: phoneName)
        case .connecting: .connecting(phoneName: phoneName)
        case .disconnecting: .disconnected(phoneName: phoneName)
        case .disconnected:
            engine.nextReconnectAttempt != nil ? .reconnecting(phoneName: phoneName) : .disconnected(phoneName: phoneName)
        }
        set(\.connection, status)
        trackStuckLink(connected: link == .connected)
        set(\.guidance, bluetoothDenied ? .bluetoothDenied
            : (showCannotConnect && link != .connected ? .cannotConnect(phoneName: engine.deviceName ?? selectedName) : linkHint))

        // Notices from the engine.
        if let failure = engine.lastCommandFailure, failure.date != seenFailureDate {
            seenFailureDate = failure.date
            Task { self.showNotice(commandFailureText()) }
        }
        if let fallback = engine.lastAudioFallback, fallback.date != seenFallbackDate {
            seenFallbackDate = fallback.date
            if let text = fallback.reason.localizedNotice { Task { self.showNotice(text) } }
        }

        // Calls.
        let call = engine.call
        set(\.callIsLive, call?.phase.isLive ?? false)
        var incoming: IncomingCallInfo?
        var active: ActiveCallInfo?
        if let call, call.id != dismissedCallID {
            let party = party(for: call.callerID)
            switch call.phase {
            case .ringing where call.direction != .outgoing:
                incoming = IncomingCallInfo(party: party, phoneName: phoneName, notice: notice)
            case .dialing:
                active = activeInfo(call, party: party, phase: call.isRemoteAlerting ? .ringing : .dialing,
                                    engine: engine, phoneName: phoneName)
            case .active:
                active = activeInfo(call, party: party, phase: .active, engine: engine, phoneName: phoneName)
            case .held:
                active = activeInfo(call, party: party, phase: .held, engine: engine, phoneName: phoneName)
            case .ended where call.direction == .outgoing || call.connectedAt != nil
                || call.endReason == .failed || call.endReason == .connectionLost:
                var info = activeInfo(call, party: party, phase: .ended, engine: engine, phoneName: phoneName)
                info.endText = (call.endReason ?? .remoteEnded).localizedText
                if let seconds = call.duration(at: .now), call.connectedAt != nil {
                    info.endDuration = CallDurationFormat.string(seconds)
                }
                active = info
            default:
                break
            }
        }
        setUI(incoming: incoming, active: active)
    }

    private func activeInfo(_ call: CallInfo, party: CallParty, phase: ActiveCallInfo.Phase,
                            engine: CallEngine, phoneName: String) -> ActiveCallInfo {
        ActiveCallInfo(
            party: party, phase: phase, startedAt: call.connectedAt, phoneName: phoneName,
            audioOnMac: engine.isAudioOnMacEnabled && engine.audioRoute == .mac, isMuted: false,
            waiting: engine.waitingCall.map { self.party(for: $0.callerID) }, notice: notice)
    }

    private func party(for callerID: CallerID) -> CallParty {
        guard let number = callerID.number else { return CallParty() }
        let match = contacts.match(for: number)
        return CallParty(displayName: match?.name, number: PhoneNumberFormat.display(number),
                         avatarPNG: match?.imageData)
    }

    private var fallbackPhoneName: String {
        String(localized: "your phone", comment: "Fallback for the phone's name, used mid-sentence, e.g. \"Call audio is on your phone\".")
    }

    private func set<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, V>, _ value: V) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func setUI(incoming: IncomingCallInfo?, active: ActiveCallInfo?) {
        if callUI.incoming != incoming { callUI.incoming = incoming }
        if callUI.active != active { callUI.active = active }
    }

    /// After 25 s without a link, hint at Bluetooth / the Pixel's "Phone calls" prompt.
    private func trackStuckLink(connected: Bool) {
        if connected {
            stuckTask?.cancel()
            stuckTask = nil
            if showCannotConnect { Task { self.showCannotConnect = false; self.apply() } }
        } else if stuckTask == nil && !showCannotConnect {
            stuckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self else { return }
                self.showCannotConnect = true
                self.apply()
            }
        }
    }

    /// Asks for Contacts and notification access once, shortly after launch and never while a call
    /// is live (a system prompt must not appear while the phone rings).
    private func requestPermissionsAfterLaunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            while self.callIsLive { try? await Task.sleep(for: .seconds(5)) }
            if self.permissions.contacts == .notDetermined, await self.permissions.requestContacts() {
                self.contacts.reload()
            }
            while self.callIsLive { try? await Task.sleep(for: .seconds(5)) }
            if self.permissions.notifications == .notDetermined {
                await self.permissions.requestNotifications()
            }
        }
    }

    // MARK: Actions

    private func makeActions() -> CallActions {
        CallActions(
            accept: { [weak self] in self?.run { try $0.accept() } },
            decline: { [weak self] in self?.run { try $0.decline() } },
            endCall: { [weak self] in self?.run { try $0.endCall() } },
            dismiss: { [weak self] in
                self?.dismissedCallID = self?.engine?.call?.id
                self?.apply()
            },
            toggleMute: {},
            sendDigit: { [weak self] digit in
                guard let digit = DTMFDigit(digit) else { return }
                self?.run { try $0.sendDTMF(digit) }
            },
            moveToPhone: { [weak self] in self?.run { try $0.transferAudioToPhone() } })
    }

    private func run(_ body: (CallEngine) throws -> Void) {
        guard let engine else { return }
        do { try body(engine) } catch { showNotice(error.pickupMessage) }
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Dials a validated number. Returns an error text, nil on success.
    /// `allowServiceCode` is true only for dial-pad input or after the user confirmed a service code from a link.
    func dial(_ number: DialNumber, allowServiceCode: Bool = false) -> String? {
        guard let engine else { return CallEngineError.notConnected.localizedText }
        do {
            try engine.dial(number, allowServiceCode: allowServiceCode)
            callUI.focusHUDWhenShown = true
            return nil
        } catch {
            return error.pickupMessage
        }
    }

    // MARK: Missed calls

    private func callFinished(_ call: CallInfo) {
        guard call.direction == .incoming, call.endReason == .missed else { return }
        let number = call.callerID.number
        let name = number.flatMap { contacts.match(for: $0)?.name }
        MissedCallNotifier.shared.notifyMissed(name: name, number: number.map { PhoneNumberFormat.display($0) })
    }

    // MARK: tel: / callto: links

    /// Handles a `tel:` / `callto:` URL. Always asks first, so a web page cannot place calls silently.
    func handle(url: URL) {
        if let last = lastHandledURL, last.url == url, Date().timeIntervalSince(last.date) < 1 { return }
        lastHandledURL = (url, Date())
        // Shown immediately; nil (invalid link) makes the window explain that instead.
        LinkCallConfirmation.shared.present(number: DialNumber(url: url), model: self)
    }

    // MARK: Demo data (static preview data, no engine involved)

    enum Demo: String { case incoming, call, remote }

    func showDemo(_ demo: Demo) {
        let party = CallParty(displayName: "Anna Schmidt", number: PhoneNumberFormat.display("+491701234567"))
        let phone = "Pixel 9 Pro"
        callUI.actions = CallActions(
            accept: { [weak self] in self?.showDemo(.call) },
            decline: { [weak self] in self?.hideDemo() },
            endCall: { [weak self] in self?.hideDemo() },
            toggleMute: { [weak self] in self?.callUI.active?.isMuted.toggle() },
            moveToPhone: { [weak self] in self?.showDemo(.remote) }
        )
        switch demo {
        case .incoming:
            callUI.active = nil
            callUI.incoming = IncomingCallInfo(party: party, phoneName: phone)
        case .call, .remote:
            callUI.incoming = nil
            callUI.active = ActiveCallInfo(party: party, phase: .active, startedAt: .now,
                                           phoneName: phone, audioOnMac: demo == .call, isMuted: false)
        }
    }

    func hideDemo() {
        callUI.incoming = nil
        callUI.active = nil
    }
}
