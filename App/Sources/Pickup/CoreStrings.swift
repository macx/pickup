import Foundation
import PickupCore

// Localized texts for the core's enums. The core exposes no strings; every user-facing wording
// lives here so it ends up in the String Catalog.

extension CallEndReason {
    /// Status line shown in the call window after a call ended.
    var localizedText: String {
        switch self {
        case .missed:
            String(localized: "Missed call", comment: "Call window status: an incoming call stopped ringing unanswered.")
        case .declined:
            String(localized: "Call declined", comment: "Call window status: the user declined an incoming call on the Mac.")
        case .cancelled:
            String(localized: "Call cancelled", comment: "Call window status: the user cancelled an outgoing call before it was answered.")
        case .unanswered:
            String(localized: "No answer", comment: "Call window status: an outgoing call was not answered (busy, rejected or no answer).")
        case .failed:
            String(localized: "Call could not be placed", comment: "Call window status: the phone did not start the outgoing call.")
        case .hungUp, .remoteEnded:
            String(localized: "Call ended", comment: "Call window status: the call is over.")
        case .connectionLost:
            String(localized: "Connection to phone lost", comment: "Call window status: the Bluetooth link dropped; the call may still run on the phone.")
        }
    }
}

extension AudioFallbackReason {
    /// Short notice for the call window; nil when nothing needs to be said.
    var localizedNotice: String? {
        switch self {
        case .audioOnMacDisabled:
            nil // Normal in remote-control mode: the conversation stays on the phone.
        case .audioSetupTimedOut:
            String(localized: "Call audio could not be started on this Mac. It stays on your phone.",
                   comment: "Notice in the call window after the audio connection to the Mac timed out.")
        case .audioDropped:
            String(localized: "Call audio on this Mac was interrupted. It moved back to your phone.",
                   comment: "Notice in the call window after the audio connection to the Mac dropped during a call.")
        case .userRequest:
            String(localized: "Call audio moved to your phone.",
                   comment: "Notice in the call window after the user chose Move to Phone.")
        }
    }
}

extension CallEngineError {
    var localizedText: String {
        switch self {
        case .notConnected:
            String(localized: "Your phone is not connected.", comment: "Error when a call action needs a Bluetooth connection that is not up.")
        case .invalidPhase:
            String(localized: "That is not possible right now.", comment: "Error when a call action does not fit the current call state, e.g. answering when nothing rings.")
        case .callInProgress:
            String(localized: "Another call is already in progress.", comment: "Error when dialing while a call is live.")
        case .serviceCodeNeedsConfirmation:
            String(localized: "This number is a service code and needs your confirmation.", comment: "Error when a number containing * or # (e.g. call forwarding) is dialed without explicit confirmation.")
        case .unsupported:
            String(localized: "Your phone does not support this.", comment: "Error when the phone or transport cannot do the requested action.")
        }
    }
}

extension Error {
    /// Localized, user-presentable text for errors thrown by the engine.
    var pickupMessage: String {
        (self as? CallEngineError)?.localizedText ?? localizedDescription
    }
}

/// Notice for a command the phone answered with an error.
func commandFailureText() -> String {
    String(localized: "Your phone could not carry out that action.",
           comment: "Notice when the phone answered a call command (answer, hang up, dial) with an error.")
}
