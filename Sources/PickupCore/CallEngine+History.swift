import Foundation

// Recent calls: when the phone's call lists are read, and the call lost with the link that is recorded only
// if it is not resumed. Split from CallEngine.swift; the state lives there.
extension CallEngine {
    /// Asks the phone for the current call list again (refreshes the number).
    /// Reads the call lists from the phone again (e.g. when the dialer opens). Skipped while a call is
    /// live, while a read is running, or if the last read started less than
    /// `callHistoryMinimumInterval` ago. Without an answer the session list stays in use.
    public func refreshCallHistory() {
        if let last = lastHistoryRequest, scheduler.now.timeIntervalSince(last) < configuration.callHistoryMinimumInterval {
            return
        }
        requestCallHistory()
    }

    /// Reads the call lists a little later: after the link came up or a call ended. A phone that
    /// refused before is not asked again automatically (only when the dialer opens).
    func scheduleHistoryRefresh() {
        guard lastHistoryRequest == nil || !callHistory.phoneRefused else { return }
        historyRefreshTask?.cancel()
        historyRefreshTask = scheduler.schedule(after: configuration.callHistoryRefreshDelay) { [weak self] in
            guard let self else { return }
            self.historyRefreshTask = nil
            self.requestCallHistory()
        }
    }

    func requestCallHistory() {
        guard !isInvalidated, linkState == .connected, !phase.isLive, !callHistory.isLoading else { return }
        lastHistoryRequest = scheduler.now
        log.log(.command, "read call history -> readCallHistory()")
        for list in CallHistoryList.allCases {
            // Registered first: a transport may answer (or fail) before the call returns.
            callHistory.requested(list)
            do {
                try transport.readCallHistory(list, count: configuration.callHistoryLength)
            } catch {
                log.log(.info, "readCallHistory(\(list.rawValue)) unavailable: \(error)")
                callHistory.received(list, entries: nil)
            }
        }
    }

    /// The call lost with the link was not resumed: into the recent calls now.
    func recordLostCall() {
        lostCallRecordTask?.cancel()
        lostCallRecordTask = nil
        guard let lost = recentlyLost else { return }
        recentlyLost = nil
        callHistory.record(lost)
    }
}
