import Foundation

// Protocol-level value types shared by every transport. Terms follow the HFP specification:
// the Mac is the hands-free unit (HF), the phone is the audio gateway (AG).

/// State of the service level connection (SLC) between the Mac and the phone.
public enum LinkState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// The `callsetup` indicator (HFP 1.8, section 4.34.2 / +CIND).
public enum CallSetupState: Int, Equatable, Sendable {
    /// No call set-up in progress.
    case none = 0
    /// Incoming call set-up (the phone is ringing).
    case incoming = 1
    /// Outgoing call set-up, the phone is dialing.
    case outgoing = 2
    /// Outgoing call set-up, the remote party is being alerted.
    case remoteAlerting = 3
}

/// The `callheld` indicator.
public enum CallHeldState: Int, Equatable, Sendable {
    /// No calls held.
    case none = 0
    /// A call is held and another one is active (or the calls were swapped).
    case activeAndHeld = 1
    /// A call is held and no call is active.
    case heldOnly = 2
}

/// One AG indicator update, already mapped from its `+CIND` index to its meaning.
public enum HFPIndicator: Equatable, Sendable {
    case service(Bool)
    case call(Bool)
    case callSetup(CallSetupState)
    case callHeld(CallHeldState)
    /// Signal strength, 0...5.
    case signal(Int)
    case roaming(Bool)
    /// Battery charge, 0...5.
    case battery(Int)
}

/// Last known value of every standard AG indicator. `nil` = not reported (yet).
public struct HFPIndicators: Equatable, Sendable {
    public var service: Bool?
    public var call: Bool?
    public var callSetup: CallSetupState?
    public var callHeld: CallHeldState?
    public var signal: Int?
    public var roaming: Bool?
    public var battery: Int?

    public init(
        service: Bool? = nil, call: Bool? = nil, callSetup: CallSetupState? = nil,
        callHeld: CallHeldState? = nil, signal: Int? = nil, roaming: Bool? = nil, battery: Int? = nil
    ) {
        self.service = service
        self.call = call
        self.callSetup = callSetup
        self.callHeld = callHeld
        self.signal = signal
        self.roaming = roaming
        self.battery = battery
    }

    /// Applies an update. Returns false if the value did not change.
    @discardableResult
    public mutating func apply(_ indicator: HFPIndicator) -> Bool {
        let before = self
        switch indicator {
        case .service(let value): service = value
        case .call(let value): call = value
        case .callSetup(let value): callSetup = value
        case .callHeld(let value): callHeld = value
        case .signal(let value): signal = value
        case .roaming(let value): roaming = value
        case .battery(let value): battery = value
        }
        return self != before
    }
}

/// Direction of a call.
public enum CallDirection: String, Equatable, Sendable {
    case incoming
    case outgoing
    /// The call was already running when the link came up and no call list has arrived yet.
    case unknown
}

/// `<stat>` field of a `+CLCC` entry.
public enum CallListStatus: Int, Equatable, Sendable {
    case active = 0
    case held = 1
    case dialing = 2
    case alerting = 3
    case incoming = 4
    case waiting = 5
    case heldByResponseAndHold = 6
}

/// One entry of the current call list (`AT+CLCC` response).
///
/// `+CLCC: <idx>,<dir>,<stat>,<mode>,<mpty>[,<number>,<type>[,<alpha>[,<priority>]]]`
public struct HFPCall: Equatable, Sendable {
    public var index: Int
    public var direction: CallDirection
    public var status: CallListStatus
    /// 0 = voice, 1 = data, 2 = fax.
    public var mode: Int
    public var isMultiparty: Bool
    /// The number as sent by the phone. Empty or nil when the caller withheld it.
    public var number: String?
    /// Type of address octet: 129 = national/unknown, 145 = international.
    public var numberType: Int?

    public init(
        index: Int, direction: CallDirection, status: CallListStatus, mode: Int = 0,
        isMultiparty: Bool = false, number: String? = nil, numberType: Int? = nil
    ) {
        self.index = index
        self.direction = direction
        self.status = status
        self.mode = mode
        self.isMultiparty = isMultiparty
        self.number = number
        self.numberType = numberType
    }
}

/// HFP commands the core cares about, classified from the AT line actually sent.
/// `other` carries only the command name (never its arguments), so it is safe to log.
public enum HFPCommand: Equatable, Sendable {
    case accept           // ATA
    case endCall          // AT+CHUP
    case dial             // ATD<number>;
    case dtmf             // AT+VTS=<digit>
    case currentCalls     // AT+CLCC
    case selectPhonebook  // AT+CPBS="<memory>"
    case readPhonebook    // AT+CPBR=<first>,<last>
    case other(String)    // e.g. "AT+BRSF", "AT+CIND?"

    public init(atCommand line: String) {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if command == "ATA" {
            self = .accept
        } else if command == "AT+CHUP" {
            self = .endCall
        } else if command.hasPrefix("ATD") {
            self = .dial
        } else if command.hasPrefix("AT+VTS") {
            self = .dtmf
        } else if command == "AT+CLCC" {
            self = .currentCalls
        } else if command.hasPrefix("AT+CPBS=\"") {
            self = .selectPhonebook
        } else if command.hasPrefix("AT+CPBR="), command != "AT+CPBR=?" {
            self = .readPhonebook
        } else {
            self = .other(HFPCommand.name(of: command))
        }
    }

    /// Command name without arguments: "AT+CMER=3,0,0,1" -> "AT+CMER=", "AT+CIND?" -> "AT+CIND?".
    static func name(of command: String) -> String {
        if let equals = command.firstIndex(of: "=") {
            let rest = command[command.index(after: equals)...]
            return String(command[...equals]) + (rest == "?" ? "?" : "")
        }
        return String(command.prefix(16))
    }

    /// Prefix of the information responses that belong to this command ("+CLCC" for AT+CLCC).
    ///
    /// Only action (`AT+CLCC`), read (`AT+CIND?`) and test (`AT+CHLD=?`) commands get information
    /// responses. Set commands (`AT+CLIP=1`, `AT+CCWA=1`) get none, and their prefix must not swallow
    /// the unsolicited result of the same name (`+CLIP:` while ringing). `AT+BRSF=` and `AT+CPBR=`
    /// are the set commands answered with information responses (`+BRSF:`, `+CPBR:`).
    static func responsePrefix(of line: String) -> String? {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard command.hasPrefix("AT+") else { return nil }
        let body = command.dropFirst(2) // "+CLCC", "+CIND=?", "+BRSF=116"
        let name = body.prefix { $0 != "=" && $0 != "?" }
        guard !name.isEmpty else { return nil }
        let rest = body.dropFirst(name.count)
        let isSetCommand = rest.hasPrefix("=") && rest != "=?"
        if isSetCommand && name != "+BRSF" && name != "+CPBR" { return nil }
        return String(name)
    }
}

/// Final result of an AT command.
public enum CommandResult: Equatable, Sendable {
    case ok
    case error
    /// `+CME ERROR: <n>` (extended error codes).
    case cmeError(Int)
    /// `+CMS ERROR: <n>` (message service errors; some AGs answer SMS probing with it).
    case cmsError(Int)
    /// Call-related final results some AGs send: NO CARRIER, BUSY, NO ANSWER, DELAYED, BLACKLISTED.
    case callFailure(String)

    public var isSuccess: Bool { self == .ok }
}
