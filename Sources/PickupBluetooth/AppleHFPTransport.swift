import Foundation
import IOBluetooth
import PickupBluetoothShim
import PickupCore

/// A paired device that can act as an HFP audio gateway, for the phone picker in Settings.
public struct PairedPhone: Equatable, Sendable, Identifiable {
    /// Bluetooth address, lowercase and dash separated (`aa-bb-cc-dd-ee-ff`).
    public let address: String
    public let name: String
    /// SDP says the device offers the HFP audio gateway role (may be false until SDP is cached).
    public let isHandsFreeAudioGateway: Bool
    public var id: String { address }
}

/// Path A transport: HFP via Apple's `IOBluetoothHandsFreeDevice`, remote control only.
///
/// The Mac is the hands-free unit, the phone the audio gateway. Audio is not supported
/// (`supportsAudio == false`): answering uses `acceptCallOnPhone()` and the core hands back any
/// SCO link the phone opens.
///
/// Rules learned on hardware (see docs/BLUETOOTH.md):
/// - **One hands-free object per phone, for the life of the process** (`HandsFreeRegistry`).
///   Every object listens for incoming connections; two objects for one phone both accept the
///   phone's reconnect and corrupt each other's command queue (crash 2026-10-11). Reconnects call
///   `connect()` on the same object; it is never released.
/// - **The phone may reconnect on its own.** `AT+BRSF` on our link while the transport is
///   disconnected is an SLC set-up started by the phone: the transport follows it. When the ACL
///   comes up, our own `connect()` waits a moment so it does not race the phone's.
/// - **Never adopt a dying or dead SLC.** A parked object's disconnect in flight is waited for;
///   after a disconnect IOBluetooth never confirmed, an SLC that still looks up is only adopted
///   after the ACL is up and an `AT+CLCC` round trip succeeded.
/// - **No calls into IOBluetooth from inside its callbacks** (delegate, RFCOMM data, write hook):
///   such calls are deferred to the next main-queue turn.
/// - Call events (indicators, RING, caller ID, call lists) are only forwarded while the link is
///   connecting or connected; audio events always.
/// - Raw AT lines come from `PickupBluetoothShim`; they are logged (sanitised, with the object
///   tag `hf#<n>`) and correlated into complete `AT+CLCC` lists and command results.
///
/// Call `invalidate()` before releasing the transport. Main thread only, like IOBluetooth.
@MainActor
public final class AppleHFPTransport: HFPTransport, ATWriteSink {
    public struct Timeouts: Equatable, Sendable {
        /// An SLC set-up that takes longer is aborted and retried with backoff. Generous because
        /// the Pixel asks the user once for "Phone calls" access during the first set-up.
        public var connect: TimeInterval = 30
        /// A disconnect IOBluetooth never confirms is abandoned after this.
        public var disconnect: TimeInterval = 10
        /// After the phone's ACL comes up, wait this long for the phone's own reconnect before
        /// starting ours.
        public var deviceAppearedDelay: TimeInterval = 2.5
        /// An SLC that still looks up after an unconfirmed disconnect must answer `AT+CLCC` within this.
        public var verifySLC: TimeInterval = 3
        /// No call list is read this soon after the SLC came up: IOBluetooth still sends its own
        /// follow-up commands then (`AT+VGS`, `AT+VGM`), and interleaving ours with them crashed
        /// IOBluetooth on 2026-10-29 (see `readCallHistory`).
        public var historyQuietPeriod: TimeInterval = 10
        /// How often a waiting call list read checks again whether the link is idle.
        public var historyRetry: TimeInterval = 0.5
        public init() {}
    }

    /// Hooks to IOBluetooth, replaceable in tests (which must not touch Bluetooth).
    struct Environment {
        var makeLink: @MainActor (_ address: String, _ delegate: HandsFreeDelegate) -> HandsFreeLink?
        var observeDeviceConnects: @MainActor (_ onConnect: @escaping @MainActor (String) -> Void) -> AnyObject?
        var installOutgoingTap: Bool
        var registry: HandsFreeRegistry
        /// Tests only (with `installOutgoingTap == false`): pretend the write hook works.
        var assumeOutgoingTap = true

        @MainActor static var live: Environment {
            Environment(
                makeLink: { address, delegate in
                    guard let device = AppleHFPTransport.pairedDevice(address: address)
                        ?? IOBluetoothDevice(addressString: address) else { return nil }
                    return IOBluetoothHandsFreeLink(device: device, delegate: delegate)
                },
                observeDeviceConnects: { onConnect in
                    let observer = DeviceConnectObserver(onConnect: onConnect)
                    observer.start()
                    return observer
                },
                installOutgoingTap: true,
                registry: .shared
            )
        }
    }

    /// After this many disconnects in a row that IOBluetooth never confirmed, `linkSetupBlocked`
    /// is reported: toggling Bluetooth or restarting Pickup may be needed.
    static let unconfirmedLimit = 3
    /// A disconnect whose SLC still looks up is repeated this often before it counts as unconfirmed.
    static let closeRetries = 2

    public let supportsAudio = false
    public private(set) var linkState: LinkState = .disconnected
    public private(set) var deviceName: String?
    public var eventHandler: ((TransportEvent) -> Void)?

    /// The phone's Bluetooth address, normalised.
    public let deviceAddress: String

    private let log: DiagnosticLogging
    private let scheduler: Scheduler
    private let timeouts: Timeouts
    private let policy: ReconnectPolicy
    private let environment: Environment
    private var registry: HandsFreeRegistry { environment.registry }
    private lazy var reconnectController = ReconnectController(policy: policy, scheduler: scheduler) { [weak self] in
        self?.openLink()
    }

    private var link: HandsFreeLink?
    private lazy var delegate: HandsFreeDelegate = {
        let delegate = HandsFreeDelegate()
        delegate.target = self
        return delegate
    }()
    private var linkTag: String { registry.tag(for: deviceAddress) }

    private var connectStartedAt: Date?
    private var connectTimer: ScheduledTask?
    private var disconnectTimer: ScheduledTask?
    private var verifyTimer: ScheduledTask?
    private var deviceAppearedTask: ScheduledTask?
    private var isInvalidated = false
    /// Nesting depth of IOBluetooth callbacks currently running (delegate, RFCOMM data, write hook).
    private var callbackDepth = 0
    /// Incremented whenever the link goes down; deferred commands of an older generation are dropped.
    private var linkGeneration = 0
    private var unconfirmedDisconnects = 0
    private var closeAttempts = 0
    private var isLinkSetupBlocked = false
    /// Waiting for a disconnect started by the previous owner; open the link when it is confirmed.
    private var openAfterInheritedClose = false
    /// An SLC that looked up after an unconfirmed disconnect is being checked with `AT+CLCC`.
    private var isVerifyingSLC = false

    private var tracker = ATExchangeTracker()
    private var incomingSanitizer = ATLogSanitizer()
    private let outgoingTapInstalled: Bool
    private var fallbackCalls: [HFPCall] = []
    /// Call lists still to be read, in request order.
    private var historyQueue: [(list: CallHistoryList, count: Int)] = []
    /// The call list read in progress: the phonebook is being selected, then read.
    private var historyStep: (list: CallHistoryList, count: Int, reading: Bool)?
    /// When the current SLC came up; call list reads wait `timeouts.historyQuietPeriod` after it.
    private var slcEstablishedAt: Date?
    private var historyRetryTask: ScheduledTask?
    private var fallbackFlush: ScheduledTask?
    private var connectObserver: AnyObject?

    /// - Parameter deviceAddress: Bluetooth address of the paired phone (any case, `:` or `-`).
    public convenience init(
        deviceAddress: String,
        log: DiagnosticLogging,
        scheduler: Scheduler? = nil,
        policy: ReconnectPolicy = ReconnectPolicy(),
        timeouts: Timeouts = Timeouts()
    ) {
        self.init(deviceAddress: deviceAddress, log: log, scheduler: scheduler, policy: policy,
                  timeouts: timeouts, environment: .live)
        deviceName = Self.pairedDevice(address: self.deviceAddress)?.name
    }

    init(
        deviceAddress: String,
        log: DiagnosticLogging,
        scheduler: Scheduler?,
        policy: ReconnectPolicy,
        timeouts: Timeouts,
        environment: Environment
    ) {
        self.deviceAddress = Self.normalizedAddress(deviceAddress)
        self.log = log
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.policy = policy
        self.timeouts = timeouts
        self.environment = environment
        environment.registry.log = log
        if environment.installOutgoingTap {
            outgoingTapInstalled = OutgoingATTap.install(log: log, registry: environment.registry) > 0
        } else {
            outgoingTapInstalled = environment.assumeOutgoingTap // tests feed `sentLine` directly
        }
        if !outgoingTapInstalled {
            log.log(.warning, "no RFCOMM write method could be hooked: outgoing AT lines are not logged, command results unknown")
        }
        reconnectController.onStateChange = { [weak self] state in
            self?.reconnectStateChanged(state)
        }
    }

    // MARK: Device lookup

    /// Paired devices that can be phones, de-duplicated by address.
    public static func pairedPhones() -> [PairedPhone] {
        var seen = Set<String>()
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).compactMap { device in
            let address = normalizedAddress(device.addressString ?? "")
            guard !address.isEmpty, seen.insert(address).inserted else { return nil }
            return PairedPhone(
                address: address,
                name: (device.name ?? address).trimmingCharacters(in: .whitespacesAndNewlines),
                isHandsFreeAudioGateway: device.isHandsFreeAudioGateway
            )
        }
    }

    nonisolated static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    static func pairedDevice(address: String) -> IOBluetoothDevice? {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .first { normalizedAddress($0.addressString ?? "") == address }
    }

    // MARK: HFPTransport: connection

    public func connect() {
        guard !isInvalidated else { return }
        log.log(.command, "connect (auto-reconnect on)")
        startObservingDeviceConnects()
        reconnectController.start()
    }

    public func disconnect() {
        log.log(.command, "disconnect (auto-reconnect off)")
        reconnectController.stop()
        openAfterInheritedClose = false
        closeLink()
    }

    public func reconnect() {
        guard !isInvalidated else { return }
        log.log(.command, "reconnect")
        startObservingDeviceConnects()
        reconnectController.resume()
    }

    public func prepareForSleep() {
        log.log(.command, "prepare for sleep")
        reconnectController.suspend()
        openAfterInheritedClose = false
        closeLink()
    }

    public func resumeAfterSleep() {
        guard !isInvalidated else { return }
        log.log(.command, "resume after sleep (\(reconnectController.state))")
        reconnectController.resumeAfterSleep()
    }

    public func invalidate() {
        guard !isInvalidated else { return }
        log.log(.command, "invalidate")
        isInvalidated = true
        reconnectController.stop()
        for task in [connectTimer, disconnectTimer, verifyTimer, deviceAppearedTask, fallbackFlush] { task?.cancel() }
        connectTimer = nil
        disconnectTimer = nil
        verifyTimer = nil
        deviceAppearedTask = nil
        fallbackFlush = nil
        historyRetryTask?.cancel()
        historyRetryTask = nil
        connectObserver = nil
        // The registry parks the object (closes its link, keeps it alive and listening) and
        // remembers a disconnect in flight for the next owner.
        registry.park(address: deviceAddress, owner: self, linkMayBeUp: linkState != .disconnected)
        link = nil
        delegate.target = nil
        setLinkState(.disconnected)
        eventHandler = nil
    }

    // MARK: HFPTransport: commands

    public func acceptCallOnPhone() throws {
        try issue("acceptCallOnPhone()") { $0.acceptCallOnPhone() }
    }

    public func endCall() throws {
        try issue("endCall()") { $0.endCall() }
    }

    public func dial(_ number: DialNumber) throws {
        let value = number.value
        try issue("dialNumber(\(number))") { $0.dialNumber(value) }
    }

    public func sendDTMF(_ digit: DTMFDigit) throws {
        let value = digit.description
        try issue("sendDTMF(\(ATLogSanitizer.hiddenDigit))") { $0.sendDTMF(value) }
    }

    public func transferAudioToPhone() throws {
        // Also while connecting: the phone may open SCO before the SLC is complete (link up mid-call).
        try issue("transferAudioToPhone()", allowWhileConnecting: true) { $0.transferAudioToPhone() }
    }

    public func requestCurrentCalls() throws {
        try issue("currentCallList()") { [weak self] link in
            if let self, !self.outgoingTapInstalled {
                self.fallbackCalls = []
                self.scheduleFallbackFlush()
            }
            link.currentCallList()
        }
    }

    public func readCallHistory(_ list: CallHistoryList, count: Int) throws {
        guard !isInvalidated else { throw TransportError.invalidated }
        // Without the write hook, the phone's answers cannot be matched to the commands.
        guard outgoingTapInstalled else { throw TransportError.unsupported }
        guard linkState == .connected, link != nil else { throw TransportError.notConnected }
        historyQueue.append((list, max(1, count)))
        sendNextHistoryCommand()
    }

    /// Starts the next queued call list read: `AT+CPBS="<list>"`, then `AT+CPBR=1,<count>` once the
    /// phone selected it (see `historyExchangeEnded`).
    ///
    /// Crash of 2026-10-29 (SIGSEGV in `-[IOBluetoothHandsFreeDevice processResultCode:]`): the read
    /// started 2 s after the SLC, while IOBluetooth's own `AT+VGS`/`AT+VGM` were still due; they went
    /// out 6 s late and IOBluetooth crashed on the next incoming data. Reads that started after those
    /// commands never failed. So a read starts only after the quiet period and when no command is
    /// waiting for its reply.
    private func sendNextHistoryCommand() {
        guard historyStep == nil, !historyQueue.isEmpty, historyRetryTask == nil else { return }
        let quietUntil = slcEstablishedAt.map { $0.addingTimeInterval(timeouts.historyQuietPeriod) } ?? scheduler.now
        if scheduler.now < quietUntil || tracker.pendingCount > 0 {
            let delay = max(quietUntil.timeIntervalSince(scheduler.now), timeouts.historyRetry)
            historyRetryTask = scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.historyRetryTask = nil
                guard self.linkState == .connected else { return }
                self.sendNextHistoryCommand()
            }
            return
        }
        let next = historyQueue.removeFirst()
        historyStep = (next.list, next.count, false)
        sendHistoryCommand("AT+CPBS=\"\(next.list.rawValue)\"")
    }

    private func sendHistoryCommand(_ line: String) {
        do {
            try issue("sendATCommand(\(line))") { $0.sendATCommand(line) }
        } catch {
            historyExchangeEnded(nil)
        }
    }

    /// The phone answered the current call list command (nil = failed, discarded or not sent).
    private func historyExchangeEnded(_ exchange: ATExchange?) {
        guard let step = historyStep else { return }
        if let exchange, exchange.result.isSuccess, !step.reading {
            historyStep = (step.list, step.count, true)
            sendHistoryCommand("AT+CPBR=1,\(step.count)")
            return
        }
        historyStep = nil
        let entries = exchange.flatMap { $0.result.isSuccess ? $0.responses.compactMap(ATParser.parseCPBR) : nil }
        emit(.callHistory(step.list, entries))
        sendNextHistoryCommand()
    }

    /// Checks the link now and runs the command on it, deferred to the next main-queue turn if an
    /// IOBluetooth callback is running (IOBluetooth's command queue is not re-entrant). A deferred
    /// command is dropped if the link went down in between.
    private func issue(_ name: String, allowWhileConnecting: Bool = false, _ command: @escaping (HandsFreeLink) -> Void) throws {
        guard !isInvalidated else { throw TransportError.invalidated }
        let allowed = linkState == .connected || (allowWhileConnecting && linkState == .connecting)
        guard allowed, link != nil else { throw TransportError.notConnected }
        let generation = linkGeneration
        let deferred = callbackDepth > 0
        log.log(.command, "\(name) [\(linkTag)\(deferred ? ", deferred: inside an IOBluetooth callback" : "")]")
        onLink(name) { [weak self] link in
            guard let self, self.linkGeneration == generation,
                  self.linkState == .connected || (allowWhileConnecting && self.linkState == .connecting) else {
                self?.log.log(.warning, "deferred \(name) dropped: the link went down")
                return
            }
            command(link)
        }
    }

    /// Runs `body` on the link now, or on the next main-queue turn while an IOBluetooth callback runs.
    private func onLink(_ name: String, _ body: @escaping (HandsFreeLink) -> Void) {
        guard let link else { return }
        guard callbackDepth > 0 else {
            body(link)
            return
        }
        let target = ObjectIdentifier(link)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.link, ObjectIdentifier(current) == target else { return }
                body(current)
            }
        }
    }

    /// Runs `body` as an IOBluetooth callback (calls into IOBluetooth inside are deferred).
    private func inCallback(_ body: () -> Void) {
        callbackDepth += 1
        defer { callbackDepth -= 1 }
        body()
    }

    // MARK: Link state machine

    /// Called by the reconnect controller.
    private func openLink() {
        guard !isInvalidated else { return }
        switch linkState {
        case .connected:
            reconnectController.linkEstablished()
            return
        case .connecting, .disconnecting:
            // A set-up (ours or the phone's) or a disconnect is running; its end reports back.
            return
        case .disconnected:
            break
        }
        guard let link = checkOutLink() else {
            reconnectController.linkFailed()
            return
        }
        tracker.reset()
        incomingSanitizer = ATLogSanitizer()
        connectStartedAt = scheduler.now

        if registry.isClosePending(address: deviceAddress) {
            // The previous owner's disconnect is still in flight: wait for it, never adopt it.
            log.log(.state, "[\(linkTag)] previous owner's disconnect still in flight; waiting for it")
            openAfterInheritedClose = true
            setLinkState(.disconnecting)
            startDisconnectTimer()
            return
        }

        if link.isConnected {
            // Never adopted on isConnected alone (it may be stale): see verifyAndAdopt.
            if link.isACLConnected {
                setLinkState(.connecting)
                verifyAndAdopt(link, reason: "SLC already looks up")
            } else {
                // Without an ACL there is no SLC: the flag is stale. Retry later with backoff.
                log.log(.state, "[\(linkTag)] SLC looks up but the ACL is down; treating it as closed")
                linkClosed()
            }
            return
        }

        setLinkState(.connecting)
        log.log(.command, "connect() -> service level connection [\(linkTag), \(registry.count) hands-free object(s) in this process]")
        let generation = linkGeneration
        onLink("connect()") { [weak self] link in
            // Deferred: only if nothing changed meanwhile (e.g. the phone's own SLC came up).
            guard let self, self.linkGeneration == generation, self.linkState == .connecting, !link.isConnected else {
                self?.log.log(.state, "deferred connect() dropped: the link changed")
                return
            }
            link.connect()
        }
        startConnectTimer()
    }

    /// Adopts an SLC that came up without a `handsFree:connected:` callback for us, but only after
    /// it answers `AT+CLCC` within `timeouts.verifySLC`; otherwise it is closed.
    private func verifyAndAdopt(_ link: HandsFreeLink, reason: String) {
        log.log(.state, "[\(linkTag)] \(reason); verifying with AT+CLCC before adopting it")
        connectTimer?.cancel()
        connectTimer = nil
        isVerifyingSLC = true
        onLink("currentCallList()") { $0.currentCallList() }
        verifyTimer?.cancel()
        verifyTimer = scheduler.schedule(after: timeouts.verifySLC) { [weak self] in
            guard let self, self.isVerifyingSLC else { return }
            self.isVerifyingSLC = false
            self.log.log(.warning, "[\(self.linkTag)] SLC did not answer AT+CLCC; closing it")
            self.closeLink()
        }
    }

    /// The link of this phone: created once per process, reused for every attempt.
    private func checkOutLink() -> HandsFreeLink? {
        if let link { return link }
        let delegate = self.delegate
        guard let link = registry.checkOut(address: deviceAddress, owner: self, make: {
            environment.makeLink(deviceAddress, delegate)
        }) else {
            log.log(.error, "no hands-free object available for \(deviceAddress)")
            return nil
        }
        let owner = ObjectIdentifier(link)
        link.attach(delegate: delegate) { [weak self] _, line, detail in
            // Called synchronously from the RFCOMM callback, before IOBluetooth handles the chunk
            // (so before the matching delegate callbacks). That is the main thread in practice;
            // hop there otherwise rather than trap.
            let deliver: @Sendable () -> Void = {
                MainActor.assumeIsolated {
                    guard let self, let current = self.link, ObjectIdentifier(current) == owner else { return }
                    self.receivedLine(line, detail: detail)
                }
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        self.link = link
        deviceName = link.deviceName ?? deviceName
        log.log(.state, "using hands-free object \(linkTag) for \(deviceAddress)")
        return link
    }

    private func startConnectTimer() {
        connectTimer?.cancel()
        connectTimer = scheduler.schedule(after: timeouts.connect) { [weak self] in
            guard let self, self.linkState == .connecting, let link = self.link else { return }
            if link.isConnected, !self.isVerifyingSLC {
                // No connected callback (e.g. a phone-initiated set-up), but the SLC looks up.
                self.verifyAndAdopt(link, reason: "no connected callback after \(Int(self.timeouts.connect)) s")
                return
            }
            self.log.log(.warning, "no SLC after \(Int(self.timeouts.connect)) s (is 'Phone calls' allowed for this Mac on the phone?); closing and retrying later")
            self.closeLink()
        }
    }

    private func closeLink() {
        switch linkState {
        case .connecting, .connected:
            break
        case .disconnecting, .disconnected:
            return
        }
        guard link != nil else {
            setLinkState(.disconnected)
            return
        }
        connectTimer?.cancel()
        connectTimer = nil
        verifyTimer?.cancel()
        verifyTimer = nil
        isVerifyingSLC = false
        closeAttempts = 0
        setLinkState(.disconnecting)
        log.log(.command, "disconnect() [\(linkTag)\(callbackDepth > 0 ? ", deferred: inside an IOBluetooth callback" : "")]")
        deferredDisconnect()
        startDisconnectTimer()
    }

    /// `disconnect()` now, or deferred; a deferred one is dropped if the link changed meanwhile.
    private func deferredDisconnect() {
        let generation = linkGeneration
        onLink("disconnect()") { [weak self] link in
            guard let self, self.linkGeneration == generation, self.linkState == .disconnecting else {
                self?.log.log(.state, "deferred disconnect() dropped: the link changed")
                return
            }
            link.disconnect()
        }
    }

    private func startDisconnectTimer() {
        disconnectTimer?.cancel()
        disconnectTimer = scheduler.schedule(after: timeouts.disconnect) { [weak self] in
            guard let self, self.linkState == .disconnecting else { return }
            if !self.openAfterInheritedClose, let link = self.link, link.isConnected, self.closeAttempts < Self.closeRetries {
                self.closeAttempts += 1
                self.log.log(.warning, "[\(self.linkTag)] SLC still up \(Int(self.timeouts.disconnect)) s after disconnect(); closing again (\(self.closeAttempts))")
                link.disconnect()
                self.startDisconnectTimer()
                return
            }
            self.unconfirmedDisconnects += 1
            self.registry.closeConfirmed(address: self.deviceAddress) // given up waiting
            self.log.log(.warning, "no disconnected callback after \(Int(self.timeouts.disconnect)) s (\(self.unconfirmedDisconnects) in a row); keeping the same hands-free object")
            if self.unconfirmedDisconnects >= Self.unconfirmedLimit {
                self.setLinkSetupBlocked(true)
            }
            self.linkClosed()
        }
    }

    /// The link is gone (confirmed or given up). Reconnects if wanted.
    private func linkClosed() {
        connectTimer?.cancel()
        connectTimer = nil
        disconnectTimer?.cancel()
        disconnectTimer = nil
        verifyTimer?.cancel()
        verifyTimer = nil
        isVerifyingSLC = false
        setLinkState(.disconnected)
        if openAfterInheritedClose {
            openAfterInheritedClose = false
            openLink()
            return
        }
        // Ignored by the controller after disconnect() (stopped) or prepareForSleep() (suspended).
        reconnectController.linkFailed()
    }

    private func slcEstablished(_ link: HandsFreeLink) {
        connectTimer?.cancel()
        connectTimer = nil
        disconnectTimer?.cancel()
        disconnectTimer = nil
        verifyTimer?.cancel()
        verifyTimer = nil
        isVerifyingSLC = false
        switch reconnectController.state {
        case .stopped, .suspended:
            // The phone reconnected on its own, but the user disconnected (or the Mac is going to
            // sleep): close it again.
            log.log(.state, "[\(linkTag)] SLC came up while no link is wanted; closing it")
            if linkState == .disconnected { setLinkState(.connecting) }
            closeLink()
            return
        default:
            break
        }
        slcEstablishedAt = scheduler.now
        setLinkState(.connected)
        unconfirmedDisconnects = 0
        setLinkSetupBlocked(false)
        reconnectController.linkEstablished()
        if let started = connectStartedAt {
            log.log(.state, String(format: "SLC took %.2f s", scheduler.now.timeIntervalSince(started)))
        }
        link.diagnostics().forEach { log.log(.state, $0) }
        let indicators = link.indicatorSnapshot()
        log.log(.state, "indicators \(indicators)")
        indicators.forEach { emit(.indicator($0)) }
        // SCO may have opened during the set-up (link came up mid-call) while the core could not
        // act on it yet; report the current state so it can hand the audio back now.
        emit(.audioConnectionChanged(isOpen: link.isSCOConnected))
    }

    /// IOBluetooth sent `AT+BRSF` (always the first SLC command) on our link while the transport is
    /// disconnected: the phone reconnected on its own and IOBluetooth runs the SLC set-up. Follow
    /// it instead of starting a second one.
    private func noteSLCStart(_ line: String) {
        guard linkState == .disconnected, !isInvalidated,
              line.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("AT+BRSF") else { return }
        log.log(.state, "[\(linkTag)] phone-initiated SLC set-up (\(registry.count) hands-free object(s) in this process)")
        deviceAppearedTask?.cancel()
        deviceAppearedTask = nil
        tracker.reset()
        incomingSanitizer = ATLogSanitizer()
        connectStartedAt = scheduler.now
        switch reconnectController.state {
        case .stopped, .suspended:
            // Not wanted (user disconnected, or going to sleep): its connected callback closes it,
            // and no call events reach the engine meanwhile.
            closeAttempts = 0
            setLinkState(.disconnecting)
            startDisconnectTimer()
        default:
            setLinkState(.connecting)
            startConnectTimer()
        }
    }

    private func linkCallbackConfirmed() {
        unconfirmedDisconnects = 0
        setLinkSetupBlocked(false)
    }

    private func setLinkSetupBlocked(_ blocked: Bool) {
        guard blocked != isLinkSetupBlocked else { return }
        isLinkSetupBlocked = blocked
        if blocked {
            log.log(.error, "IOBluetooth did not confirm \(unconfirmedDisconnects) disconnects in a row; Bluetooth may need to be toggled")
        }
        emit(.linkSetupBlocked(blocked))
    }

    private func setLinkState(_ state: LinkState) {
        guard state != linkState else { return }
        log.log(.state, "link \(linkState.rawValue) -> \(state.rawValue) [\(linkTag)]")
        linkState = state
        if state == .disconnected || state == .disconnecting {
            linkGeneration += 1
        }
        if state != .connected {
            tracker.reset()
            historyQueue.removeAll()
            historyStep = nil
            historyRetryTask?.cancel()
            historyRetryTask = nil
            slcEstablishedAt = nil
        }
        emit(.linkStateChanged(state))
    }

    private func reconnectStateChanged(_ state: ReconnectController.State) {
        if case .waiting(let until) = state {
            log.log(.state, "reconnect attempt \(reconnectController.failures + 1) in \(String(format: "%.0f", until.timeIntervalSince(scheduler.now))) s")
            emit(.reconnectScheduled(until))
        } else {
            emit(.reconnectScheduled(nil))
        }
    }

    private func isCurrent(_ device: AnyObject?, _ callback: String) -> Bool {
        if let device, let link, device === link.underlying { return true }
        log.log(.warning, "\(callback) from an object that is not \(linkTag), ignored")
        return false
    }

    // MARK: Device connect notifications

    /// When the phone's baseband link comes up (back in range, Bluetooth toggled), skip the
    /// remaining backoff wait, but give the phone a moment to reconnect on its own first: our
    /// `connect()` must not race its set-up on the same object.
    private func startObservingDeviceConnects() {
        guard connectObserver == nil else { return }
        connectObserver = environment.observeDeviceConnects { [weak self] address in
            guard let self, Self.normalizedAddress(address) == self.deviceAddress else { return }
            self.deviceAppeared()
        }
    }

    func deviceAppeared() {
        log.log(.delegate, "device ACL connected [\(linkTag)]")
        guard linkState == .disconnected, deviceAppearedTask == nil else { return }
        deviceAppearedTask = scheduler.schedule(after: timeouts.deviceAppearedDelay) { [weak self] in
            guard let self else { return }
            self.deviceAppearedTask = nil
            guard self.linkState == .disconnected, !(self.link?.isConnected ?? false) else { return }
            self.reconnectController.deviceAppeared()
        }
    }

    // MARK: Raw AT lines

    func sentLine(_ line: String, detail: String?, channel: AnyObject) {
        let owned = link?.owns(channel: channel) ?? false
        let tag = owned ? linkTag : "other channel, not tracked"
        let suffix = (detail.map { "    [\($0)]" } ?? "") + "    [\(tag)]"
        if line == "(write failed)" {
            log.log(.at, ">> (write failed)" + suffix)
            if owned { inCallback { handle(tracker.writeFailed()) } }
            return
        }
        log.log(.at, ">> \(ATLogSanitizer.outgoing(line))" + suffix)
        guard owned else { return }
        // Runs inside IOBluetooth's write (inside its command queue): defer any command.
        inCallback {
            noteSLCStart(line)
            handle(tracker.outgoing(line, at: scheduler.now))
        }
    }

    func receivedLine(_ line: String, detail: String?) {
        log.log(.at, "<< \(incomingSanitizer.incoming(line))" + (detail.map { "    [\($0)]" } ?? "") + "    [\(linkTag)]")
        if isVerifyingSLC, !outgoingTapInstalled, ATParser.parse(line).finalResult != nil, let link {
            // No write hook, so AT+CLCC cannot be matched: any final result proves the SLC alive.
            log.log(.state, "[\(linkTag)] SLC answered after the probe; adopting it")
            inCallback { slcEstablished(link) }
            return
        }
        inCallback {
            handle(tracker.incoming(line, at: scheduler.now))
        }
    }

    private func handle(_ outputs: [ATExchangeTracker.Output]) {
        for output in outputs {
            switch output {
            case .unsolicited(.callWaiting(let number)):
                // IOBluetooth has no delegate callback for +CCWA.
                emit(.callWaiting(number))
            case .unsolicited, .response:
                break // Indicators, RING and +CLIP arrive through the delegate.
            case .discarded(let command):
                log.log(.warning, "no reply to \(command); dropped from the command queue")
                if command == .selectPhonebook || command == .readPhonebook { historyExchangeEnded(nil) }
            case .completed(let exchange):
                if isVerifyingSLC, exchange.command == .currentCalls, let link {
                    log.log(.state, "[\(linkTag)] SLC answered AT+CLCC (\(exchange.result)); adopting it")
                    slcEstablished(link)
                }
                if exchange.command == .currentCalls, exchange.result.isSuccess {
                    emit(.currentCalls(exchange.currentCalls))
                }
                emit(.commandCompleted(exchange.command, exchange.result))
                if exchange.command == .selectPhonebook || exchange.command == .readPhonebook {
                    historyExchangeEnded(exchange)
                }
            }
        }
    }

    private func scheduleFallbackFlush() {
        fallbackFlush?.cancel()
        fallbackFlush = scheduler.schedule(after: 1.0) { [weak self] in
            guard let self else { return }
            self.fallbackFlush = nil
            self.emit(.currentCalls(self.fallbackCalls))
            self.fallbackCalls = []
        }
    }

    /// Forwards an event. Call events of a link that is not (being) set up are dropped: they belong
    /// to an SLC nobody wants (e.g. one completing during a disconnect).
    private func emit(_ event: TransportEvent) {
        switch event {
        case .indicator, .ring, .callerID, .callWaiting, .currentCalls, .commandCompleted, .callHistory:
            guard linkState == .connecting || linkState == .connected else {
                log.log(.state, "dropped \(event) while \(linkState.rawValue) [\(linkTag)]")
                return
            }
        case .linkStateChanged, .reconnectScheduled, .linkSetupBlocked, .audioConnectionChanged:
            break
        }
        eventHandler?(event)
    }
}

// MARK: - Delegate callbacks

extension AppleHFPTransport: HandsFreeDelegateTarget {
    func logDelegate(_ message: String) {
        log.log(.delegate, "\(message) [\(linkTag)]")
    }

    func handsFree(_ device: AnyObject?, connectedWithStatus status: Int32) {
        guard isCurrent(device, "connected"), let link else { return }
        inCallback {
            connectTimer?.cancel()
            connectTimer = nil
            linkCallbackConfirmed()
            if status != 0 {
                log.log(.warning, "SLC set-up failed")
                if linkState == .disconnecting || linkState == .connecting {
                    linkClosed()
                }
                return
            }
            if linkState == .disconnecting {
                let closeWanted: Bool
                switch reconnectController.state {
                case .stopped, .suspended: closeWanted = true
                default: closeWanted = openAfterInheritedClose
                }
                if closeWanted {
                    // The user, sleep or the previous owner wants this link closed.
                    log.log(.state, "[\(linkTag)] SLC completed during a disconnect; closing it again")
                    deferredDisconnect()
                    return
                }
                // We only gave up on an earlier set-up; this SLC is fresh and confirmed.
                log.log(.state, "[\(linkTag)] fresh SLC completed while closing an earlier attempt; adopting it")
            }
            slcEstablished(link)
        }
    }

    func handsFree(_ device: AnyObject?, disconnectedWithStatus status: Int32) {
        guard isCurrent(device, "disconnected") else { return }
        inCallback {
            linkCallbackConfirmed()
            registry.closeConfirmed(address: deviceAddress)
            if linkState == .connecting, !isVerifyingSLC {
                // Late callback of the previous link; the set-up now running is unaffected.
                log.log(.state, "[\(linkTag)] late disconnected callback during a set-up; ignored for the state")
                return
            }
            linkClosed()
        }
    }

    func handsFree(_ device: AnyObject?, audioOpened: Bool, status: Int32) {
        guard isCurrent(device, audioOpened ? "scoConnectionOpened" : "scoConnectionClosed") else { return }
        if audioOpened, status != 0 { return } // SCO set-up failed; nothing to hand back.
        inCallback { emit(.audioConnectionChanged(isOpen: audioOpened)) }
    }

    func handsFree(_ device: AnyObject?, indicator: HFPIndicator) {
        guard isCurrent(device, "indicator") else { return }
        inCallback { emit(.indicator(indicator)) }
    }

    func handsFreeRing(_ device: AnyObject?) {
        guard isCurrent(device, "ringAttempt") else { return }
        inCallback { emit(.ring) }
    }

    func handsFree(_ device: AnyObject?, callerID: String) {
        guard isCurrent(device, "incomingCallFrom") else { return }
        inCallback { emit(.callerID(callerID)) }
    }

    func handsFree(_ device: AnyObject?, currentCall: HFPCall) {
        guard isCurrent(device, "currentCall") else { return }
        // With the raw tap the complete list arrives via the AT+CLCC exchange instead.
        guard !outgoingTapInstalled else { return }
        fallbackCalls.append(currentCall)
        scheduleFallbackFlush()
    }
}

// MARK: - Outgoing AT tap

/// Process-wide hook on `IOBluetoothRFCOMMChannel` writes (installed once). Every outgoing line
/// goes to the registry, which hands it to the owner of the channel's hands-free object.
@MainActor
private enum OutgoingATTap {
    private static var hookCount: Int?
    private static weak var registry: HandsFreeRegistry?

    /// Lets the (non-Sendable) channel cross to the main queue; it is only used there.
    private struct ChannelBox: @unchecked Sendable {
        let channel: IOBluetoothRFCOMMChannel
    }

    /// Returns the number of hooked write methods.
    static func install(log: DiagnosticLogging, registry: HandsFreeRegistry) -> Int {
        Self.registry = registry
        if let hookCount { return hookCount }
        let count = PUBInstallRFCOMMWriteLogging { channel, line, detail in
            // Logging only, never back into IOBluetooth: the transport defers any call it makes
            // while a callback runs. RFCOMM writes normally happen on the main thread.
            let box = ChannelBox(channel: channel)
            let deliver: @Sendable () -> Void = {
                MainActor.assumeIsolated {
                    OutgoingATTap.registry?.routeWrite(line, detail: detail, channel: box.channel)
                }
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        hookCount = count
        log.log(.info, "outgoing AT logging: \(count) RFCOMM write method(s) hooked")
        return count
    }
}

// MARK: - Device connect observer

/// Wraps `IOBluetoothDevice.register(forConnectNotifications:selector:)`.
private final class DeviceConnectObserver: NSObject {
    private let onConnect: @MainActor (String) -> Void
    private var notification: IOBluetoothUserNotification?

    init(onConnect: @escaping @MainActor (String) -> Void) {
        self.onConnect = onConnect
    }

    func start() {
        notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    deinit {
        notification?.unregister()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        let onConnect = self.onConnect
        let deliver: () -> Void = { MainActor.assumeIsolated { onConnect(address) } }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}
