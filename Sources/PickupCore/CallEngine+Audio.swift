import Foundation

// Call audio: handing SCO back to the phone (remote-control mode and the per-call fallback). Split from
// CallEngine.swift; the state lives there.
extension CallEngine {
    /// Per-call fallback: move the audio to the phone and leave a notice. The call continues in
    /// remote-control mode. Safe to call in any mode and phase. Returns false if the transport
    /// could not send the request (it is retried when the link comes up).
    @discardableResult
    public func handBackAudioToPhone(_ reason: AudioFallbackReason) -> Bool {
        log.log(.command, "hand audio back to phone (\(reason.rawValue)) -> transferAudioToPhone()")
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        do {
            try transport.transferAudioToPhone()
        } catch {
            log.log(.error, "transferAudioToPhone failed: \(error)")
            return false
        }
        expectingAudioClose = true
        lastAudioFallback = AudioFallback(reason: reason, date: scheduler.now, callID: call?.id)
        return true
    }

    func audioConnectionChanged(isOpen: Bool) {
        if isOpen {
            // The transport re-reports an open SCO after the SLC is up; a hand-back may be under way.
            let handBackPending = audioRoute == .mac && expectingAudioClose
            audioRoute = .mac
            audioWatchdogTask?.cancel()
            audioWatchdogTask = nil
            if !isAudioOnMacEnabled, !handBackPending {
                // Remote-control mode: the phone opened SCO on its own; the conversation belongs on the phone.
                handBackAudioToPhone(.audioOnMacDisabled)
            }
        } else {
            let wasOnMac = audioRoute == .mac
            audioRoute = .phone
            if wasOnMac, !expectingAudioClose, isAudioOnMacEnabled, phase == .active || phase == .held {
                lastAudioFallback = AudioFallback(reason: .audioDropped, date: scheduler.now, callID: call?.id)
                log.log(.warning, "audio link dropped during the call; audio is on the phone now")
            }
            expectingAudioClose = false
        }
    }

    func startAudioWatchdog() {
        guard isAudioOnMacEnabled else { return }
        audioWatchdogTask?.cancel()
        audioWatchdogTask = scheduler.schedule(after: configuration.audioSetupTimeout) { [weak self] in
            guard let self else { return }
            self.audioWatchdogTask = nil
            if self.audioRoute != .mac, self.phase == .active {
                self.handBackAudioToPhone(.audioSetupTimedOut)
            }
        }
    }
}
