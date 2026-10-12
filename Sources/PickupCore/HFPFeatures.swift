import Foundation

/// Human-readable decoding of HFP feature bitmaps (HFP 1.8 bit numbering), for diagnostics.
public enum HFPFeatures {
    static func decode(_ value: UInt32, _ names: [String]) -> String {
        let set = names.enumerated()
            .filter { value & (1 << UInt32($0.offset)) != 0 }
            .map(\.element)
        return String(format: "0x%04x ", value) + "[" + set.joined(separator: ", ") + "]"
    }

    /// AG features as sent in `+BRSF`.
    public static func audioGateway(_ value: UInt32) -> String {
        decode(value, [
            "3-way calling", "EC/NR", "voice recognition", "in-band ring", "voice tag",
            "reject call", "enhanced call status", "enhanced call control", "extended error codes",
            "codec negotiation", "HF indicators", "eSCO S4", "enhanced VR status", "VR text",
        ])
    }

    /// HF features as sent in `AT+BRSF`.
    public static func handsFree(_ value: UInt32) -> String {
        decode(value, [
            "EC/NR", "3-way calling", "CLI presentation", "voice recognition", "remote volume",
            "enhanced call status", "enhanced call control", "codec negotiation", "HF indicators",
            "eSCO S4", "enhanced VR status", "VR text",
        ])
    }

    /// IOBluetooth call hold modes bitmap (`+CHLD` values).
    public static func callHoldModes(_ value: UInt32) -> String {
        decode(value, ["0", "1", "1x", "2", "2x", "3", "4"])
    }
}
