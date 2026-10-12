import AppKit
import Foundation

/// Stress test for the call banner/HUD: cycles the call UI through incoming -> active -> held -> ended ->
/// hidden -> dialing -> ringing -> ended quickly, changing notices, a waiting caller, the timer and the
/// end text, so panel resizes happen constantly. Run with `-PickupSelfTestCallCycle <N>` (needs `-PickupDemo`
/// so no Bluetooth is used). Survival is the first assertion (the old layout feedback loop overflowed the
/// stack); the second is that the panels keep one top-right corner. Result: `NSTemporaryDirectory()/callcycle.txt`.
@MainActor
enum CallCycleSelfTest {
    static func run(cycles: Int, interval: Duration = .milliseconds(25)) {
        Task { @MainActor in
            let model = AppModel.shared
            let ui = model.callUI
            let party = CallParty(displayName: "Anna Schmidt", number: "+49 170 1234567")
            let unknown = CallParty(displayName: nil, number: "+49 30 555123")
            let longNotice = "Call audio on this Mac was interrupted. It moved back to your phone, and this is a long notice to force wrapping."
            func active(_ phase: ActiveCallInfo.Phase, audio: Bool = false, started: Bool = true, waiting: CallParty? = nil,
                        notice: String? = nil, end: String? = nil) -> ActiveCallInfo {
                ActiveCallInfo(party: party, phase: phase, startedAt: started ? Date().addingTimeInterval(-3725) : nil,
                               phoneName: "Pixel 9 Pro", audioOnMac: audio, isMuted: false,
                               endText: end, endDuration: end == nil ? nil : "1:02:05", waiting: waiting, notice: notice)
            }
            let steps: [() -> Void] = [
                { ui.active = nil; ui.incoming = IncomingCallInfo(party: party, phoneName: "Pixel 9 Pro") },
                { ui.incoming = IncomingCallInfo(party: unknown, phoneName: "Pixel 9 Pro", notice: longNotice) },
                { ui.incoming = nil; ui.active = active(.active) },
                { ui.active = active(.active, waiting: unknown) },
                { ui.active = active(.active, audio: true, waiting: unknown, notice: longNotice) },
                { ui.active = active(.held, audio: true) },
                { ui.active = active(.ended, end: "Call ended") },
                { ui.active = nil; ui.incoming = nil },
                { ui.active = active(.dialing, started: false) },
                { ui.active = active(.ringing, started: false, notice: longNotice) },
                { ui.active = active(.ended, started: false, end: "No answer") },
                { ui.active = nil },
            ]
            var corners = Set<String>()
            var minHeight = CGFloat.greatestFiniteMagnitude, maxHeight: CGFloat = 0, samples = 0
            for _ in 0..<cycles {
                for step in steps {
                    step()
                    try? await Task.sleep(for: interval)
                    // A panel whose content is empty (fading out) may be collapsed to zero size; skip those.
                    for frame in model.panels.debugVisibleFrames where frame.width > 1 {
                        corners.insert("\(Int(frame.maxX.rounded())),\(Int(frame.maxY.rounded()))")
                        minHeight = min(minHeight, frame.height)
                        maxHeight = max(maxHeight, frame.height)
                        samples += 1
                    }
                }
            }
            ui.active = nil; ui.incoming = nil
            let verdict = corners.count <= 1 ? "OK" : "DRIFT"
            let line = "\(verdict) cycles=\(cycles) samples=\(samples) corners=\(corners.sorted()) heights=\(minHeight)...\(maxHeight)\n"
            try? line.write(toFile: NSTemporaryDirectory() + "callcycle.txt", atomically: true, encoding: .utf8)
            if UserDefaults.standard.bool(forKey: "PickupSelfTestExit") { NSApp.terminate(nil) }
        }
    }
}
