import Foundation

/// Phase of the call shown by the UI: idle → ringing/dialing → active ⇄ held → ended.
public enum CallPhase: String, Equatable, Sendable {
    case idle
    /// Incoming call, the phone is ringing.
    case ringing
    /// Outgoing call being set up (see `CallInfo.isRemoteAlerting`).
    case dialing
    case active
    /// The call is on hold (`callheld=2`).
    case held
    /// The call is over; see `CallInfo.endReason`. The engine returns to `idle` after
    /// `CallEngine.Configuration.endedDisplayDuration`.
    case ended

    /// Ringing, dialing, active or held.
    public var isLive: Bool {
        switch self {
        case .ringing, .dialing, .active, .held: return true
        case .idle, .ended: return false
        }
    }
}

/// What is known about the other party's number.
public enum CallerID: Equatable, Sendable {
    /// Not known (yet): the call list has not answered or did not contain the call.
    case unknown
    /// The phone reported the call without a number (caller withheld it).
    case withheld
    case number(String)

    public var number: String? {
        if case .number(let number) = self { return number }
        return nil
    }

    init(listedNumber: String?) {
        if let listedNumber, !listedNumber.isEmpty {
            self = .number(listedNumber)
        } else {
            self = .withheld
        }
    }
}

/// Why a call ended. The UI maps this to a localized text; the core exposes no strings.
public enum CallEndReason: String, Equatable, Sendable {
    /// Incoming call stopped ringing without being answered or declined on this Mac.
    /// (Declined on the phone or hung up by the caller look the same over HFP.)
    case missed
    /// Incoming call declined on this Mac.
    case declined
    /// Outgoing call cancelled on this Mac before it was answered.
    case cancelled
    /// Outgoing call ended before it was answered (busy, rejected, no answer, cancelled on the phone).
    case unanswered
    /// The phone refused the dial command or never started the call.
    case failed
    /// Hung up on this Mac.
    case hungUp
    /// Ended by the other party or on the phone.
    case remoteEnded
    /// The link to the phone dropped. The call may still be running on the phone.
    case connectionLost
}

/// The call the UI shows. Value type; the engine replaces it on every change.
public struct CallInfo: Equatable, Sendable, Identifiable {
    public let id: UUID
    public internal(set) var direction: CallDirection
    public internal(set) var callerID: CallerID
    public internal(set) var phase: CallPhase
    /// When ringing/dialing started, or when the call was first seen.
    public let startedAt: Date
    /// When the conversation started (call indicator became 1). Drives the duration display.
    public internal(set) var connectedAt: Date?
    /// True if the call was already running when Pickup learned about it (link came up mid-call),
    /// so `connectedAt` is only a lower bound.
    public internal(set) var connectedAtIsApproximate: Bool
    /// Outgoing only: the remote party is being alerted (`callsetup=3`).
    public internal(set) var isRemoteAlerting: Bool
    public internal(set) var endedAt: Date?
    public internal(set) var endReason: CallEndReason?

    public var number: String? { callerID.number }

    /// Conversation duration at `date` (or at the end), nil before the call was answered.
    public func duration(at date: Date) -> TimeInterval? {
        guard let connectedAt else { return nil }
        return max(0, (endedAt ?? date).timeIntervalSince(connectedAt))
    }

    init(direction: CallDirection, callerID: CallerID, phase: CallPhase, startedAt: Date) {
        self.id = UUID()
        self.direction = direction
        self.callerID = callerID
        self.phase = phase
        self.startedAt = startedAt
        self.connectedAt = nil
        self.connectedAtIsApproximate = false
        self.isRemoteAlerting = false
        self.endedAt = nil
        self.endReason = nil
    }
}

/// Where the call audio currently plays.
public enum AudioRoute: String, Equatable, Sendable {
    case phone
    case mac
}

/// Why the engine moved the audio back to the phone (per-call fallback).
public enum AudioFallbackReason: String, Equatable, Sendable {
    /// The phone opened SCO although audio on the Mac is off (remote-control mode).
    case audioOnMacDisabled
    /// Audio on the Mac is on, but SCO did not come up in time.
    case audioSetupTimedOut
    /// SCO dropped during the call.
    case audioDropped
    /// The user chose "Move to phone".
    case userRequest
}

public struct AudioFallback: Equatable, Sendable {
    public let reason: AudioFallbackReason
    public let date: Date
    public let callID: UUID?
}

/// A command the phone answered with an error, for a short notice in the UI.
public struct CommandFailure: Equatable, Sendable {
    public let command: HFPCommand
    public let result: CommandResult
    public let date: Date
}

/// Phone status for the menu bar (from the AG indicators). nil = unknown / not connected.
public struct PhoneStatus: Equatable, Sendable {
    public var hasService: Bool?
    /// 0...5
    public var signal: Int?
    public var isRoaming: Bool?
    /// 0...5
    public var battery: Int?

    public init(hasService: Bool? = nil, signal: Int? = nil, isRoaming: Bool? = nil, battery: Int? = nil) {
        self.hasService = hasService
        self.signal = signal
        self.isRoaming = isRoaming
        self.battery = battery
    }
}

/// Errors thrown by `CallEngine` commands.
public enum CallEngineError: Error, Equatable, Sendable {
    case notConnected
    /// The command does not fit the current phase (e.g. accept while nothing rings).
    case invalidPhase(CallPhase)
    /// Dialing while another call is live (three-way calling is not supported yet).
    case callInProgress
    case unsupported
    /// The number is an MMI/USSD code (`*`/`#`) and `allowServiceCode` was not set.
    case serviceCodeNeedsConfirmation
}
