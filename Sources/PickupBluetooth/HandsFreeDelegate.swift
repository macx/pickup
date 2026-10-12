// swiftlint:disable implicitly_unwrapped_optional - the IOBluetooth delegate protocols are declared with `!` parameters
import Foundation
import IOBluetooth
import PickupCore

/// What `HandsFreeDelegate` reports to its transport. Main actor only.
@MainActor
protocol HandsFreeDelegateTarget: AnyObject {
    func handsFree(_ device: AnyObject?, connectedWithStatus status: Int32)
    func handsFree(_ device: AnyObject?, disconnectedWithStatus status: Int32)
    func handsFree(_ device: AnyObject?, audioOpened: Bool, status: Int32)
    func handsFree(_ device: AnyObject?, indicator: HFPIndicator)
    func handsFreeRing(_ device: AnyObject?)
    func handsFree(_ device: AnyObject?, callerID: String)
    func handsFree(_ device: AnyObject?, currentCall: HFPCall)
    func logDelegate(_ message: String)
}

/// Receives `IOBluetoothHandsFreeDeviceDelegate` callbacks for one hands-free object.
///
/// `IOBluetoothHandsFree.delegate` is `assign`, so the transport keeps this object alive for as
/// long as IOBluetooth may call it (see `AppleHFPTransport.retire`).
///
/// All delegate methods are optional in Objective-C, so a Swift signature that does not match
/// would silently never be called. Every method therefore pins its exact selector with @objc(...).
/// IOBluetooth calls back on the run loop the object was created on (the main thread).
final class HandsFreeDelegate: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    weak var target: HandsFreeDelegateTarget?

    private func onMain(_ body: @escaping @MainActor (HandsFreeDelegateTarget) -> Void) {
        let deliver: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let target = self?.target else { return }
                body(target)
            }
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    static func ioReturn(_ status: NSNumber?) -> Int32 {
        status?.int32Value ?? -1
    }

    static func describe(_ status: Int32) -> String {
        status == 0 ? "0x00000000 (success)" : String(format: "0x%08x", UInt32(bitPattern: status))
    }

    // MARK: IOBluetoothHandsFreeDelegate (connection / SCO)

    @objc(handsFree:connected:)
    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        let code = Self.ioReturn(status)
        onMain { target in
            target.logDelegate("connected status=\(Self.describe(code))")
            target.handsFree(device, connectedWithStatus: code)
        }
    }

    @objc(handsFree:disconnected:)
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        let code = Self.ioReturn(status)
        onMain { target in
            target.logDelegate("disconnected status=\(Self.describe(code))")
            target.handsFree(device, disconnectedWithStatus: code)
        }
    }

    @objc(handsFree:scoConnectionOpened:)
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        let code = Self.ioReturn(status)
        onMain { target in
            target.logDelegate("scoConnectionOpened status=\(Self.describe(code))")
            target.handsFree(device, audioOpened: true, status: code)
        }
    }

    @objc(handsFree:scoConnectionClosed:)
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        let code = Self.ioReturn(status)
        onMain { target in
            target.logDelegate("scoConnectionClosed status=\(Self.describe(code))")
            target.handsFree(device, audioOpened: false, status: code)
        }
    }

    // MARK: IOBluetoothHandsFreeDeviceDelegate (indicators, +CIEV)

    private func indicator(_ device: AnyObject?, _ name: String, _ value: NSNumber?, _ map: @escaping (Int) -> HFPIndicator?) {
        let raw = value?.intValue ?? -1
        onMain { target in
            target.logDelegate("indicator \(name)=\(raw)")
            if let indicator = map(raw) {
                target.handsFree(device, indicator: indicator)
            }
        }
    }

    @objc(handsFree:isServiceAvailable:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable: NSNumber!) {
        indicator(device, "service", isServiceAvailable) { .service($0 != 0) }
    }

    @objc(handsFree:isCallActive:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive: NSNumber!) {
        indicator(device, "call", isCallActive) { .call($0 != 0) }
    }

    @objc(handsFree:callSetupMode:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode: NSNumber!) {
        indicator(device, "callsetup", callSetupMode) { CallSetupState(rawValue: $0).map(HFPIndicator.callSetup) }
    }

    @objc(handsFree:callHoldState:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callHoldState: NSNumber!) {
        indicator(device, "callheld", callHoldState) { CallHeldState(rawValue: $0).map(HFPIndicator.callHeld) }
    }

    @objc(handsFree:signalStrength:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength: NSNumber!) {
        indicator(device, "signal", signalStrength) { .signal($0) }
    }

    @objc(handsFree:isRoaming:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isRoaming: NSNumber!) {
        indicator(device, "roam", isRoaming) { .roaming($0 != 0) }
    }

    @objc(handsFree:batteryCharge:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge: NSNumber!) {
        indicator(device, "battchg", batteryCharge) { .battery($0) }
    }

    // MARK: Calls

    @objc(handsFree:incomingCallFrom:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        let number = number ?? ""
        onMain { target in
            target.logDelegate("incomingCallFrom number=\(number)")
            target.handsFree(device, callerID: number)
        }
    }

    @objc(handsFree:ringAttempt:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt: NSNumber!) {
        let count = ringAttempt?.intValue ?? -1
        onMain { target in
            target.logDelegate("ringAttempt count=\(count)")
            target.handsFreeRing(device)
        }
    }

    @objc(handsFree:currentCall:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall: [AnyHashable: Any]!) {
        let dictionary = currentCall ?? [:]
        let fields = dictionary.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let call = Self.call(from: dictionary)
        onMain { target in
            target.logDelegate("currentCall \(fields)")
            if let call {
                target.handsFree(device, currentCall: call)
            }
        }
    }

    @objc(handsFree:subscriberNumber:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, subscriberNumber: String!) {
        let number = subscriberNumber ?? "nil"
        onMain { $0.logDelegate("subscriberNumber \(number)") }
    }

    @objc(handsFree:incomingSMS:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingSMS sms: [AnyHashable: Any]!) {
        // Message content is deliberately not logged; keys only.
        let keys = (sms ?? [:]).keys.map { "\($0)" }.sorted().joined(separator: ",")
        onMain { $0.logDelegate("incomingSMS keys=[\(keys)]") }
    }

    @objc(handsFree:unhandledResultCode:)
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode resultCode: String!) {
        // Only the result code name: the line may be a contact name field or an SMS body.
        // The full (sanitised) line is in the AT log from the raw tap.
        let code = Self.resultCodeName(resultCode ?? "nil")
        onMain { $0.logDelegate("unhandledResultCode '\(code)'") }
    }

    /// `+BSIR: 1` -> `+BSIR`; a line that is not a `+XXX:` result code -> `<n chars>`.
    static func resultCodeName(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+"), let colon = trimmed.firstIndex(of: ":"),
           trimmed[trimmed.index(after: trimmed.startIndex)..<colon].allSatisfy({ $0.isLetter || $0.isNumber }) {
            return String(trimmed[..<colon])
        }
        if ["RING", "OK", "ERROR"].contains(trimmed) { return trimmed }
        return "<\(trimmed.count) chars>"
    }

    /// Maps IOBluetooth's current-call dictionary. Keys seen with the Pixel (phase 0):
    /// direction, index, mode, mulitiparty (sic), number, status, type.
    static func call(from dictionary: [AnyHashable: Any]) -> HFPCall? {
        func int(_ key: String) -> Int? {
            (dictionary[key] as? NSNumber)?.intValue ?? (dictionary[key] as? String).flatMap { Int($0) }
        }
        guard let index = int("index"), let statusValue = int("status"),
              let status = CallListStatus(rawValue: statusValue) else { return nil }
        return HFPCall(
            index: index,
            direction: int("direction") == 1 ? .incoming : .outgoing,
            status: status,
            mode: int("mode") ?? 0,
            isMultiparty: (int("mulitiparty") ?? int("multiparty") ?? 0) == 1,
            number: dictionary["number"] as? String,
            numberType: int("type")
        )
    }
}
