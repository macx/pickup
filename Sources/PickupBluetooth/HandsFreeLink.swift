// swiftlint:disable implicitly_unwrapped_optional - the IOBluetooth delegate protocols are declared with `!` parameters
import Foundation
import IOBluetooth
import PickupBluetoothShim
import PickupCore

/// The hands-free object of one phone, as `AppleHFPTransport` uses it. Wraps
/// `IOBluetoothHandsFreeDevice` in production; tests substitute a fake (no Bluetooth access).
@MainActor
protocol HandsFreeLink: AnyObject {
    /// The object IOBluetooth passes to delegate callbacks (identity checks only).
    var underlying: AnyObject { get }
    /// Service level connection is up (as IOBluetooth believes; may be stale after a lost link).
    var isConnected: Bool { get }
    var isSCOConnected: Bool { get }
    /// The phone's baseband (ACL) link is up.
    var isACLConnected: Bool { get }
    var deviceName: String? { get }

    /// Makes `delegate` receive the callbacks and `incoming` the raw AT lines. Every delegate ever
    /// attached is kept alive by the link (`delegate` is `assign` in IOBluetooth).
    func attach(delegate: HandsFreeDelegate, incoming: @escaping PUBATLogHandler)
    /// No transport owns the link any more: callbacks go to a delegate that closes any SLC the
    /// phone opens from now on (the object keeps listening for incoming connections) and reports
    /// `onClosed` when IOBluetooth confirms a disconnect.
    func park(onClosed: @escaping @MainActor () -> Void)

    func connect()
    func disconnect()
    func acceptCallOnPhone()
    func endCall()
    func dialNumber(_ number: String)
    func sendDTMF(_ digit: String)
    func transferAudioToPhone()
    func currentCallList()

    /// True if `channel` (an `IOBluetoothRFCOMMChannel`) belongs to this link.
    func owns(channel: AnyObject) -> Bool
    /// Indicator values IOBluetooth tracked during the SLC set-up.
    func indicatorSnapshot() -> [HFPIndicator]
    /// Feature bitmaps and similar, for the log.
    func diagnostics() -> [String]
}

/// Production link: one `PUBLoggingHandsFreeDevice` (an `IOBluetoothHandsFreeDevice`).
@MainActor
final class IOBluetoothHandsFreeLink: HandsFreeLink {
    let device: PUBLoggingHandsFreeDevice
    private var delegates: [NSObject] = []

    init?(device: IOBluetoothDevice, delegate: HandsFreeDelegate) {
        guard let handsFree = PUBLoggingHandsFreeDevice(device: device, delegate: delegate) else { return nil }
        self.device = handsFree
        delegates.append(delegate)
    }

    var underlying: AnyObject { device }
    var isConnected: Bool { device.isConnected }
    var isSCOConnected: Bool { device.isSCOConnected() }
    var isACLConnected: Bool { device.device?.isConnected() ?? false }
    var deviceName: String? { device.device?.name }

    func attach(delegate: HandsFreeDelegate, incoming: @escaping PUBATLogHandler) {
        if !delegates.contains(where: { $0 === delegate }) { delegates.append(delegate) }
        device.delegate = delegate
        device.incomingHandler = incoming
    }

    func park(onClosed: @escaping @MainActor () -> Void) {
        let reaper = ReaperDelegate(onClosed: onClosed)
        delegates.append(reaper)
        device.incomingHandler = nil
        device.delegate = reaper
        if device.isConnected { device.disconnect() }
    }

    func connect() { device.connect() }
    func disconnect() { device.disconnect() }
    func acceptCallOnPhone() { device.acceptCallOnPhone() }
    func endCall() { device.endCall() }
    func dialNumber(_ number: String) { device.dialNumber(number) }
    func sendDTMF(_ digit: String) { device.sendDTMF(digit) }
    func transferAudioToPhone() { device.transferAudioToPhone() }
    func currentCallList() { device.currentCallList() }

    func owns(channel: AnyObject) -> Bool {
        guard let channel = channel as? IOBluetoothRFCOMMChannel else { return false }
        return device.ownsChannel(channel)
    }

    func indicatorSnapshot() -> [HFPIndicator] {
        let value = { (key: String) in Int(self.device.indicator(key)) }
        var indicators: [HFPIndicator] = [
            .service(value(IOBluetoothHandsFreeIndicatorService) != 0),
            .call(value(IOBluetoothHandsFreeIndicatorCall) != 0),
            .signal(value(IOBluetoothHandsFreeIndicatorSignal)),
            .roaming(value(IOBluetoothHandsFreeIndicatorRoam) != 0),
            .battery(value(IOBluetoothHandsFreeIndicatorBattChg)),
        ]
        if let setup = CallSetupState(rawValue: value(IOBluetoothHandsFreeIndicatorCallSetup)) {
            indicators.append(.callSetup(setup))
        }
        if let held = CallHeldState(rawValue: value(IOBluetoothHandsFreeIndicatorCallHeld)) {
            indicators.append(.callHeld(held))
        }
        return indicators
    }

    func diagnostics() -> [String] {
        [
            "AG features (+BRSF) " + HFPFeatures.audioGateway(device.deviceSupportedFeatures),
            "AG call hold modes (+CHLD) " + HFPFeatures.callHoldModes(device.deviceCallHoldModes),
            "HF features (ours) " + HFPFeatures.handsFree(device.supportedFeatures),
            "SCO connected=\(device.isSCOConnected())",
        ]
    }
}

/// Delegate of a parked link: closes any SLC the phone opens while no transport owns the link,
/// and reports confirmed disconnects. Never calls IOBluetooth from inside its callback.
final class ReaperDelegate: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    private let onClosed: @MainActor () -> Void

    init(onClosed: @escaping @MainActor () -> Void) {
        self.onClosed = onClosed
    }

    /// Lets the (non-Sendable) device cross to the next main-queue turn; only used there.
    private struct DeviceBox: @unchecked Sendable { let device: IOBluetoothHandsFree }

    @objc(handsFree:connected:)
    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        guard status?.int32Value == 0, let device else { return }
        let box = DeviceBox(device: device)
        DispatchQueue.main.async { box.device.disconnect() }
    }

    @objc(handsFree:disconnected:)
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        let onClosed = self.onClosed
        DispatchQueue.main.async { MainActor.assumeIsolated { onClosed() } }
    }
}

/// Receives outgoing AT lines routed by the registry.
@MainActor
protocol ATWriteSink: AnyObject {
    func sentLine(_ line: String, detail: String?, channel: AnyObject)
}

/// One hands-free object per phone for the life of the process.
///
/// Root cause of the 2026-10-11 reconnect crash (stack overflow in
/// `-[IOBluetoothHandsFreeDevice sendPendingATCommand]`): `initWithDevice:delegate:` registers a
/// listener for incoming connections, and that listener stays active for as long as the object
/// lives. After a drop the transport created a new object while the old one was kept alive (it
/// must not be freed, IOBluetooth holds unretained pointers to it). When the Pixel reconnected on
/// its own, *both* objects accepted the connection and ran their SLC set-up on the same RFCOMM
/// channel; each consumed the other's replies and IOBluetooth's command queue recursed until the
/// stack overflowed. So an object is created once per phone, reused for every reconnect and
/// handed to the next transport for the same phone; it is never released.
///
/// The registry also remembers a disconnect still in flight when an owner parks the object, so the
/// next owner does not adopt a dying SLC.
@MainActor
final class HandsFreeRegistry {
    static let shared = HandsFreeRegistry()

    /// A parked object's pending disconnect is assumed finished (or lost) after this.
    var closeTimeout: TimeInterval = 10
    var log: DiagnosticLogging?
    private let now: () -> Date

    private final class Entry {
        let link: HandsFreeLink
        let tag: String
        weak var owner: AnyObject?
        var closeStartedAt: Date?
        init(link: HandsFreeLink, tag: String) {
            self.link = link
            self.tag = tag
        }
    }

    private var entries: [String: Entry] = [:]
    private var nextTag = 1

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Number of hands-free objects created in this process (one per phone).
    var count: Int { entries.count }

    /// Log tag of the object for `address` (`hf#1`), stable for the life of the process.
    func tag(for address: String) -> String {
        entries[address]?.tag ?? "hf#-"
    }

    /// The link for `address`, created with `make` the first time. Nil if another live owner holds
    /// it (two transports for one phone would bring back the double-SLC race) or `make` fails.
    func checkOut(address: String, owner: AnyObject, make: () -> HandsFreeLink?) -> HandsFreeLink? {
        if let entry = entries[address] {
            if let current = entry.owner, current !== owner {
                log?.log(.error, "hands-free object \(entry.tag) for \(address) is owned by another transport; refusing a second owner")
                return nil
            }
            entry.owner = owner
            return entry.link
        }
        guard let link = make() else { return nil }
        let entry = Entry(link: link, tag: "hf#\(nextTag)")
        nextTag += 1
        entry.owner = owner
        entries[address] = entry
        log?.log(.state, "created hands-free object \(entry.tag) for \(address) (\(entries.count) in this process)")
        return link
    }

    /// The owner gives the link up (transport invalidated): it is parked, not released.
    /// `linkMayBeUp`: the owner's link was connecting, connected or disconnecting.
    func park(address: String, owner: AnyObject, linkMayBeUp: Bool) {
        guard let entry = entries[address], entry.owner === owner else { return }
        entry.owner = nil
        if linkMayBeUp { entry.closeStartedAt = now() }
        entry.link.park { [weak self] in self?.closeConfirmed(address: address) }
        log?.log(.state, "parked hands-free object \(entry.tag)" + (linkMayBeUp ? " (disconnect in flight)" : ""))
    }

    /// A disconnect started by a previous owner has not been confirmed yet (within `closeTimeout`).
    func isClosePending(address: String) -> Bool {
        guard let started = entries[address]?.closeStartedAt else { return false }
        return now().timeIntervalSince(started) < closeTimeout
    }

    func closeConfirmed(address: String) {
        guard let entry = entries[address], entry.closeStartedAt != nil else { return }
        entry.closeStartedAt = nil
        log?.log(.state, "hands-free object \(entry.tag): disconnect confirmed")
    }

    /// Routes an outgoing AT line to the owner of the channel's object (the RFCOMM write hook is
    /// process-wide). Lines of parked or unknown channels are only logged.
    func routeWrite(_ line: String, detail: String?, channel: AnyObject) {
        if let entry = entries.values.first(where: { $0.link.owns(channel: channel) }) {
            if let sink = entry.owner as? ATWriteSink {
                sink.sentLine(line, detail: detail, channel: channel)
            } else {
                log?.log(.at, ">> \(ATLogSanitizer.outgoing(line))    [parked \(entry.tag)]")
            }
            return
        }
        log?.log(.at, ">> \(ATLogSanitizer.outgoing(line))    [unknown channel]")
        if line.uppercased().hasPrefix("AT+BRSF") {
            // Signature of the 2026-10-11 crash: a second hands-free session starting its SLC.
            log?.log(.error, "an SLC set-up started on a channel no hands-free object of Pickup owns (\(entries.count) object(s) in this process)")
        }
    }
}
