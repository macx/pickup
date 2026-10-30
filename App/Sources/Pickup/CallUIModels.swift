import Foundation

// Plain value types the call UI renders. The real CallEngine (PickupCore) is mapped onto
// these in one place (see AppModel.bind…); views never import Bluetooth or core types.

/// The other party of a call. Either field may be missing (the Pixel does not always report a number).
struct CallParty: Equatable, Sendable {
    var displayName: String?
    var number: String?
    var avatarPNG: Data?

    /// Primary line: name, else number, else nil (caller shows the localized "Unknown caller").
    var primaryText: String? { displayName ?? number }
    /// Secondary line: the number, only when a name is shown as the primary line.
    var secondaryText: String? { displayName == nil ? nil : number }

    var initials: String? {
        guard let name = displayName else { return nil }
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}

struct IncomingCallInfo: Equatable, Sendable {
    var party: CallParty
    var phoneName: String
    /// Short transient message (e.g. a command the phone rejected).
    var notice: String? = nil
}

struct ActiveCallInfo: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Outgoing call being set up.
        case dialing
        /// Outgoing call, the remote party is being alerted.
        case ringing
        case active
        case held
        /// The call is over; `endText` says why.
        case ended
    }
    var party: CallParty
    var phase: Phase
    /// Start of the conversation; drives the timer. Nil until answered.
    var startedAt: Date?
    var phoneName: String
    /// True when call audio runs through this Mac (`supportsAudio` and "Take calls on this Mac").
    /// False = remote-control mode: no mute, keypad or "Move to Phone".
    var audioOnMac: Bool
    var isMuted: Bool
    /// Localized reason and formatted duration, only in `.ended`.
    var endText: String? = nil
    var endDuration: String? = nil
    /// A second caller waiting on the line.
    var waiting: CallParty? = nil
    /// A second call on hold while this one is active.
    var held: CallParty? = nil
    /// The phone supports holding, swapping and taking a waiting call.
    var canHold = false
    var notice: String? = nil
    /// The user pressed End Call and the phone has not confirmed yet: the button shows progress.
    var isEnding = false
}

/// Actions the views trigger. The engine binding supplies real closures.
struct CallActions {
    var accept: () -> Void = {}
    var decline: () -> Void = {}
    var endCall: () -> Void = {}
    var dismiss: () -> Void = {}
    var toggleMute: () -> Void = {}
    var sendDigit: (Character) -> Void = { _ in }
    var moveToPhone: () -> Void = {}
    var toggleHold: () -> Void = {}
    var swapCalls: () -> Void = {}
    /// Take the waiting call and hold the current one.
    var acceptWaitingHolding: () -> Void = {}
    /// Take the waiting call and end the current one.
    var acceptWaitingEnding: () -> Void = {}
    var rejectWaiting: () -> Void = {}
    var endHeld: () -> Void = {}
}

enum ConnectionStatus: Equatable {
    case noPhone
    case connected(phoneName: String)
    case connecting(phoneName: String)
    /// Link is down and the transport retries with backoff.
    case reconnecting(phoneName: String)
    case disconnected(phoneName: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// How an ended call is presented.
enum EndedCallPresentation {
    /// Whether the HUD stays on screen with the "ended" state (reason and Close). A call the user ended
    /// on this Mac (hung up or cancelled) closes the HUD as soon as the phone confirms: the End Call
    /// button already showed the progress, and a second state would only repeat what the user did.
    static func showsEndedState(reasonEndedOnMac: Bool, isOutgoing: Bool, wasConnected: Bool,
                                failedOrLinkLost: Bool) -> Bool {
        if reasonEndedOnMac { return false }
        return isOutgoing || wasConnected || failedOrLinkLost
    }
}

/// Progress of End Call pressed on this Mac, until the phone ends the call. Cleared when the phone
/// rejects the command (the user can retry at once) or when an attempt times out; a timeout of an
/// earlier attempt never clears a later retry.
struct HangUpProgress: Equatable {
    private(set) var callID: UUID?
    private(set) var attempt = 0

    func isEnding(_ id: UUID) -> Bool { callID == id }

    /// Starts an attempt and returns its number (pass it to `timedOut`).
    mutating func start(_ id: UUID) -> Int {
        callID = id
        attempt += 1
        return attempt
    }

    mutating func commandFailed() { callID = nil }

    mutating func timedOut(attempt: Int) {
        if attempt == self.attempt { callID = nil }
    }
}
