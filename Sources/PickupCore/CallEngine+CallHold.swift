import Foundation

// Three-way calling (AT+CHLD): hold and resume, swap, and the waiting call (take it holding or ending the
// current call, or decline it). Split from CallEngine.swift to keep the type readable; the state lives there.
extension CallEngine {
    /// Puts the call on hold, or resumes it. Only with a single call.
    public func toggleHold() throws {
        try requireCallHold()
        guard heldCall == nil, waitingCall == nil, phase == .active || phase == .held else {
            throw CallEngineError.invalidPhase(phase)
        }
        try sendHold(.holdActiveAcceptOther, .toggle)
    }

    /// Swaps the active and the held call.
    public func swapCalls() throws {
        try requireCallHold()
        // With a third (waiting) caller, CHLD=2 would take that call instead of swapping.
        guard heldCall != nil, waitingCall == nil, phase == .active else { throw CallEngineError.invalidPhase(phase) }
        try sendHold(.holdActiveAcceptOther, .swap)
    }

    /// Takes the waiting call. `endingCurrent`: ends the current call instead of holding it. With a
    /// call already on hold, only ending the current call is possible.
    public func acceptWaitingCall(endingCurrent: Bool) throws {
        try requireCallHold()
        guard waitingCall != nil, phase == .active || phase == .held else { throw CallEngineError.invalidPhase(phase) }
        guard endingCurrent || heldCall == nil else { throw CallEngineError.unsupported }
        // CHLD=1 ends active calls only: a call that is on hold would stay, not end.
        guard !endingCurrent || phase == .active else { throw CallEngineError.invalidPhase(phase) }
        if endingCurrent, let call { localEndRequestedFor = call.id }
        try sendHold(endingCurrent ? .releaseActiveAcceptOther : .holdActiveAcceptOther,
                     endingCurrent ? .acceptWaitingEnding : .acceptWaitingHolding)
    }

    /// Rejects the waiting call; the current call goes on.
    public func rejectWaitingCall() throws {
        try requireCallHold()
        guard waitingCall != nil else { throw CallEngineError.invalidPhase(phase) }
        try sendHold(.releaseHeldOrRejectWaiting, .rejectWaiting)
    }

    /// Ends the held call; the active call goes on.
    public func endHeldCall() throws {
        try requireCallHold()
        guard heldCall != nil, waitingCall == nil else { throw CallEngineError.invalidPhase(phase) }
        try sendHold(.releaseHeldOrRejectWaiting, .endHeld)
    }

    func requireCallHold() throws {
        try requireConnected()
        guard transport.supportsCallHold else { throw CallEngineError.unsupported }
    }

    /// One three-way calling command at a time: a reply could otherwise be taken for the wrong request.
    func sendHold(_ action: CallHoldAction, _ request: HoldRequest) throws {
        guard holdRequest == nil else { throw CallEngineError.invalidPhase(phase) }
        log.log(.command, "call hold \(action.rawValue) (\(request)) -> callHold()")
        try perform { try transport.callHold(action) }
        holdRequest = request
        holdTimeoutTask?.cancel()
        holdTimeoutTask = scheduler.schedule(after: configuration.callHoldReplyTimeout) { [weak self] in
            guard let self, self.holdRequest != nil else { return }
            self.log.log(.warning, "no answer to the call hold command; giving up")
            if self.holdRequest == .endActive || self.holdRequest == .acceptWaitingEnding { self.localEndRequestedFor = nil }
            self.holdRequest = nil
            self.holdTimeoutTask = nil
            if self.phase.isLive { self.requestCallList(resetAttempts: true) }
        }
    }

    /// A waiting caller that stopped ringing and was not taken (declined or gave up): a missed call
    /// (recent calls, red dot, notification).
    func finalizeResolvedWaiting() {
        resolvedWaitingTask?.cancel()
        resolvedWaitingTask = nil
        guard let waiting = resolvedWaiting?.call else { return }
        resolvedWaiting = nil
        recordBackground(waiting, .missed)
    }

    var recentlyResolvedWaiting: CallInfo? {
        guard let resolvedWaiting,
              scheduler.now.timeIntervalSince(resolvedWaiting.at) <= configuration.waitingCallTakenWindow else { return nil }
        return resolvedWaiting.call
    }

    /// The waiting call becomes the active call; the current one is held or ended.
    func promoteWaiting(holdingCurrent: Bool) {
        guard let waiting = waitingCall ?? recentlyResolvedWaiting, var current = call,
              current.phase == .active || current.phase == .held else { return }
        waitingCall = nil
        resolvedWaiting = nil
        resolvedWaitingTask?.cancel()
        resolvedWaitingTask = nil
        var next = waiting
        next.phase = .active
        next.connectedAt = scheduler.now
        if holdingCurrent {
            transition(&current, to: .held)
            heldCall = current
        } else {
            finish(localEndRequestedFor == current.id ? .hungUp : .remoteEnded)
            endedClearTask?.cancel()
            endedClearTask = nil
        }
        log.log(.state, "call \(next.id.uuidString.prefix(8)) waiting -> active\(holdingCurrent ? "; previous call held" : "")")
        self.call = next
        if next.callerID == .unknown { requestCallList(resetAttempts: true) }
    }

    /// The active call ended; the held call takes its place (`phase`: held, or active when the phone
    /// resumed it).
    func resumeHeld(after reason: CallEndReason, phase: CallPhase) {
        guard let held = heldCall else { return }
        heldCall = nil
        holdRequest = nil
        finish(reason)
        endedClearTask?.cancel()
        endedClearTask = nil
        var resumed = held
        transition(&resumed, to: phase)
        self.call = resumed
    }

    func swapActiveAndHeld() {
        guard var active = call, var held = heldCall, active.phase == .active else { return }
        transition(&active, to: .held)
        transition(&held, to: .active)
        heldCall = active
        self.call = held
    }

    /// A call that ended while it was not the shown call (held or waiting): into the recent calls.
    func recordBackground(_ background: CallInfo, _ reason: CallEndReason) {
        var ended = background
        ended.phase = .ended
        ended.endedAt = scheduler.now
        ended.endReason = reason
        log.log(.state, "call \(ended.id.uuidString.prefix(8)) ended in the background: \(reason.rawValue)")
        callHistory.record(ended)
        onCallFinished?(ended)
    }

    /// The phone answered a three-way calling command. Success applies the request (unless an
    /// indicator already did); the call list then confirms numbers and states.
    func holdCompleted(_ result: CommandResult) {
        guard let request = holdRequest else { return }
        holdRequest = nil
        holdTimeoutTask?.cancel()
        holdTimeoutTask = nil
        guard result.isSuccess else {
            lastCommandFailure = CommandFailure(command: .callHold, result: result, date: scheduler.now)
            if request == .endActive || request == .acceptWaitingEnding { localEndRequestedFor = nil }
            log.log(.warning, "phone rejected the call hold command (\(request)): \(result)")
            return
        }
        switch request {
        case .toggle:
            break // The callheld indicator moves the call between active and held.
        case .swap:
            swapActiveAndHeld()
        case .acceptWaitingHolding:
            promoteWaiting(holdingCurrent: true)
        case .acceptWaitingEnding:
            promoteWaiting(holdingCurrent: false)
        case .rejectWaiting:
            if let waiting = waitingCall {
                waitingCall = nil
                recordBackground(waiting, .declined)
            }
        case .endActive:
            if let call, heldCall != nil {
                resumeHeld(after: localEndRequestedFor == call.id ? .hungUp : .remoteEnded, phase: .active)
            }
        case .endHeld:
            if let held = heldCall {
                heldCall = nil
                recordBackground(held, .hungUp)
            }
        }
        if phase.isLive { requestCallList(resetAttempts: true) }
    }
}
