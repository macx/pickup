import Foundation

/// Exponential backoff for reconnect attempts.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Delay before the first retry after a failure or a dropped link.
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maximumDelay: TimeInterval

    public init(initialDelay: TimeInterval = 2, multiplier: Double = 2, maximumDelay: TimeInterval = 60) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
    }

    /// Delay before retry number `failures` (1 = first retry): 2, 4, 8, 16, 32, 60, 60, ... s.
    public func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 30))
        return min(initialDelay * pow(multiplier, exponent), maximumDelay)
    }
}

/// Keeps a link up: decides when to attempt a (re)connect. Transport-neutral.
///
/// The transport calls `start()` / `stop()` for the user's intent, reports outcomes with
/// `linkEstablished()` / `linkFailed()`, and forwards sleep/wake with `suspend()` / `resume()`.
/// The controller calls `attempt` whenever the transport should try to open the link.
@MainActor
public final class ReconnectController {
    public enum State: Equatable, Sendable {
        /// The user does not want a link (never started, or `stop()`).
        case stopped
        /// An attempt is in progress.
        case attempting
        case connected
        /// Waiting for the next attempt.
        case waiting(until: Date)
        /// System sleep; no attempts until `resume()`.
        case suspended
    }

    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    /// Consecutive failed attempts since the last established link.
    public private(set) var failures = 0
    public var onStateChange: ((State) -> Void)?

    private let policy: ReconnectPolicy
    private let scheduler: Scheduler
    private let attempt: () -> Void
    private var timer: ScheduledTask?

    public init(policy: ReconnectPolicy = ReconnectPolicy(), scheduler: Scheduler, attempt: @escaping () -> Void) {
        self.policy = policy
        self.scheduler = scheduler
        self.attempt = attempt
    }

    /// The user wants the link: attempt now with a fresh backoff.
    public func start() {
        failures = 0
        attemptNow()
    }

    /// The user closed the link: no more attempts.
    public func stop() {
        cancelTimer()
        state = .stopped
    }

    /// Sleep: cancel pending attempts. A failure reported while suspended does not schedule one.
    public func suspend() {
        guard state != .stopped else { return }
        cancelTimer()
        state = .suspended
    }

    /// Explicit user request: attempt now with a fresh backoff (also from `stopped`).
    public func resume() {
        if state == .connected || state == .attempting { return }
        start()
    }

    /// System wake: attempt now with a fresh backoff, but only if the link was wanted before
    /// (`suspended` by sleep, or `waiting` for a retry). After `stop()` the user chose to stay
    /// disconnected, so nothing happens.
    public func resumeAfterSleep() {
        switch state {
        case .suspended, .waiting:
            start()
        case .stopped, .attempting, .connected:
            break
        }
    }

    /// The phone showed up (e.g. its ACL link came up): skip the remaining wait.
    public func deviceAppeared() {
        guard case .waiting = state else { return }
        attemptNow()
    }

    public func linkEstablished() {
        cancelTimer()
        failures = 0
        state = .connected
    }

    /// An attempt failed or an established link dropped.
    public func linkFailed() {
        switch state {
        case .stopped, .suspended:
            return
        case .waiting:
            return // already scheduled
        case .attempting, .connected:
            failures += 1
            let delay = policy.delay(afterFailures: failures)
            let until = scheduler.now.addingTimeInterval(delay)
            state = .waiting(until: until)
            timer = scheduler.schedule(after: delay) { [weak self] in
                guard let self, case .waiting = self.state else { return }
                self.attemptNow()
            }
        }
    }

    private func attemptNow() {
        cancelTimer()
        state = .attempting
        attempt()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
