import Foundation

/// Everything a transport reports to the core. Delivered on the main actor, in order.
public enum TransportEvent: Equatable, Sendable {
    /// The service level connection changed state.
    case linkStateChanged(LinkState)
    /// When the next automatic reconnect attempt is due; nil = no attempt scheduled.
    case reconnectScheduled(Date?)
    /// True after several disconnects in a row that the Bluetooth stack never confirmed: the link
    /// may be wedged. The transport keeps retrying; the UI may suggest toggling Bluetooth or
    /// restarting Pickup. Cleared when the stack reports again or a link is established.
    case linkSetupBlocked(Bool)
    /// An AG indicator changed (or was reported initially after the SLC came up).
    case indicator(HFPIndicator)
    /// `RING`. Phase 0 with the Pixel: sent only while a headset is connected to the phone;
    /// otherwise only `callsetup=1` arrives.
    case ring
    /// `+CLIP` caller ID. Same as `RING`: the Pixel sends it only with a headset connected;
    /// otherwise the number comes from the call list (`AT+CLCC`).
    case callerID(String)
    /// `+CCWA`: a second incoming call while a call is active. Empty number = withheld.
    case callWaiting(String)
    /// The complete current call list (`AT+CLCC` answered with `OK`). Empty = no calls.
    case currentCalls([HFPCall])
    /// The phone answered a command with its final result code.
    case commandCompleted(HFPCommand, CommandResult)
    /// A call list read with `readCallHistory`, newest first; nil = the phone refused it (no access
    /// to the call history granted), does not support it or did not answer.
    case callHistory(CallHistoryList, [CallHistoryEntry]?)
    /// A call list read got no answer in time (the link is not taking commands). Not a refusal: the
    /// lists already shown stay, and the next refresh asks again.
    case callHistoryUnanswered(CallHistoryList)
    /// The audio link (SCO) opened or closed. Remote-control transports may still report it,
    /// because the phone can open SCO on its own; the core then hands the audio back.
    case audioConnectionChanged(isOpen: Bool)
}

/// Why a transport refused a command.
public enum TransportError: Error, Equatable, Sendable {
    /// No service level connection.
    case notConnected
    /// The transport cannot do this (e.g. audio on a remote-control-only transport).
    case unsupported
    /// `invalidate()` was called; the transport is unusable.
    case invalidated
}

/// A connection to the phone that speaks HFP semantics: Apple's IOBluetooth stack (path A),
/// a companion app (path B) or a USB dongle running BTstack (audio extension).
///
/// The core never knows which one it is talking to. Mode = `supportsAudio` + the user setting
/// "Take calls on this Mac"; nothing in the core may only work in one of the two modes.
///
/// All commands are fire-and-forget: the phone's answer arrives as
/// `TransportEvent.commandCompleted`, and its effect as indicator changes.
@MainActor
public protocol HFPTransport: AnyObject {
    /// True if this transport can carry call audio between the phone and the Mac (SCO).
    var supportsAudio: Bool { get }
    var linkState: LinkState { get }
    /// Human-readable name of the phone, if known (e.g. "Pixel 9 Pro").
    var deviceName: String? { get }
    /// Receives every transport event. Set by `CallEngine`; one consumer only.
    var eventHandler: ((TransportEvent) -> Void)? { get set }

    /// Opens the link and keeps it up: reconnects automatically (with backoff) when it drops.
    func connect()
    /// Closes the link and stops reconnecting until `connect()` or `reconnect()` is called.
    func disconnect()
    /// Re-establishes the link now with a fresh backoff, on an explicit user request
    /// (also after `disconnect()`).
    func reconnect()
    /// Closes the link cleanly before the system sleeps and pauses reconnecting.
    /// Call `resumeAfterSleep()` after wake.
    func prepareForSleep()
    /// After wake: reconnects only if the link was wanted before sleep (never after `disconnect()`).
    func resumeAfterSleep()
    /// Closes the link for good and parks all Bluetooth objects safely. Must be called before the
    /// transport is released (e.g. when the user picks another phone). Idempotent; afterwards every
    /// command throws `TransportError.invalidated` and connection requests are ignored.
    func invalidate()

    /// Answers the ringing call; the audio stays on (or returns to) the phone. `ATA`.
    func acceptCallOnPhone() throws
    /// Rejects the ringing call or ends the active call. `AT+CHUP`.
    func endCall() throws
    /// Places an outgoing call. `ATD<number>;`
    func dial(_ number: DialNumber) throws
    /// Sends one DTMF tone during an active call. `AT+VTS=<digit>`
    func sendDTMF(_ digit: DTMFDigit) throws
    /// Moves the call audio to the phone (closes SCO). The per-call fallback of the audio extension.
    /// Works while the link is still being set up too: the phone may open SCO before the SLC is
    /// complete when the link comes up during a call.
    func transferAudioToPhone() throws
    /// Asks for the current call list. `AT+CLCC`; the answer arrives as `.currentCalls`.
    func requestCurrentCalls() throws
    /// Reads the newest `count` entries of a call list (`AT+CPBS="DC"`, then `AT+CPBR=1,<count>`).
    /// The answer arrives as `.callHistory`. Requests are queued and answered in order.
    func readCallHistory(_ list: CallHistoryList, count: Int) throws
    /// True if the phone supports three-way calling (`+BRSF` and `+CHLD` modes 0, 1 and 2).
    var supportsCallHold: Bool { get }
    /// Holds, resumes, swaps or ends calls, or answers/rejects a waiting call. `AT+CHLD=<n>`;
    /// the answer arrives as `.commandCompleted(.callHold, …)`, the effect as indicator changes.
    func callHold(_ action: CallHoldAction) throws
}

public extension HFPTransport {
    /// Transports without access to the phone's call lists.
    func readCallHistory(_ list: CallHistoryList, count: Int) throws {
        throw TransportError.unsupported
    }

    /// Transports without three-way calling.
    var supportsCallHold: Bool { false }

    func callHold(_ action: CallHoldAction) throws {
        throw TransportError.unsupported
    }
}
