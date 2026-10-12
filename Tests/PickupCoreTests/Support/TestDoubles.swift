import Foundation
@testable import PickupCore

/// Deterministic clock and timers: nothing runs until the test advances time.
@MainActor
final class ManualScheduler: Scheduler {
    private(set) var now: Date
    private var tasks: [Entry] = []
    private var sequence = 0

    private final class Entry: ScheduledTask {
        let due: Date
        let order: Int
        let action: @MainActor () -> Void
        var isCancelled = false

        init(due: Date, order: Int, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.order = order
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    var pendingCount: Int { tasks.filter { !$0.isCancelled }.count }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        sequence += 1
        let entry = Entry(due: now.addingTimeInterval(max(0, delay)), order: sequence, action: action)
        tasks.append(entry)
        return entry
    }

    func advance(by interval: TimeInterval) {
        advance(to: now.addingTimeInterval(interval))
    }

    /// Runs every task due up to `date` in due order, including tasks scheduled while running.
    func advance(to date: Date) {
        while let next = tasks.filter({ !$0.isCancelled && $0.due <= date })
            .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = max(now, next.due)
            next.action()
        }
        tasks.removeAll { $0.isCancelled }
        now = max(now, date)
    }
}

/// Records commands and lets the test emit transport events.
@MainActor
final class MockHFPTransport: HFPTransport {
    enum Command: Equatable {
        case connect, disconnect, reconnect, prepareForSleep, resumeAfterSleep, invalidate
        case acceptCallOnPhone, endCall, dial(String), sendDTMF(String), transferAudioToPhone, requestCurrentCalls
    }

    var supportsAudio = false
    private(set) var linkState: LinkState = .disconnected
    var deviceName: String? = "Pixel 9 Pro"
    var eventHandler: ((TransportEvent) -> Void)?
    private(set) var commands: [Command] = []

    func emit(_ event: TransportEvent) {
        if case .linkStateChanged(let state) = event {
            linkState = state
        }
        eventHandler?(event)
    }

    func emit(_ indicator: HFPIndicator) {
        emit(.indicator(indicator))
    }

    /// Brings the link up like IOBluetooth does: initial indicators arrive before `connected`.
    func bringUp(call: Bool = false, callSetup: CallSetupState = .none, callHeld: CallHeldState = .none) {
        emit(.linkStateChanged(.connecting))
        emit(.call(call))
        emit(.callSetup(callSetup))
        emit(.service(true))
        emit(.signal(5))
        emit(.roaming(false))
        emit(.battery(4))
        emit(.callHeld(callHeld))
        emit(.linkStateChanged(.connected))
    }

    func clearCommands() { commands.removeAll() }

    func count(_ command: Command) -> Int { commands.filter { $0 == command }.count }

    // MARK: HFPTransport

    func connect() { commands.append(.connect) }
    func disconnect() { commands.append(.disconnect) }
    func reconnect() { commands.append(.reconnect) }
    func prepareForSleep() { commands.append(.prepareForSleep) }
    func resumeAfterSleep() { commands.append(.resumeAfterSleep) }
    func invalidate() {
        commands.append(.invalidate)
        isInvalidated = true
        emit(.linkStateChanged(.disconnected))
    }

    private(set) var isInvalidated = false
    /// Lets `transferAudioToPhone` succeed while connecting, like `AppleHFPTransport`.
    var allowsAudioTransferWhileConnecting = true
    /// Makes `transferAudioToPhone` throw.
    var failTransferAudio = false

    private func record(_ command: Command) throws {
        guard !isInvalidated else { throw TransportError.invalidated }
        guard linkState == .connected else { throw TransportError.notConnected }
        commands.append(command)
    }

    func acceptCallOnPhone() throws { try record(.acceptCallOnPhone) }
    func endCall() throws { try record(.endCall) }
    func dial(_ number: DialNumber) throws { try record(.dial(number.value)) }
    func sendDTMF(_ digit: DTMFDigit) throws { try record(.sendDTMF(digit.description)) }
    func transferAudioToPhone() throws {
        if failTransferAudio { throw TransportError.notConnected }
        if allowsAudioTransferWhileConnecting, linkState == .connecting {
            commands.append(.transferAudioToPhone)
            return
        }
        try record(.transferAudioToPhone)
    }
    func requestCurrentCalls() throws { try record(.requestCurrentCalls) }
}

/// Collects log lines in memory.
final class MemoryLog: DiagnosticLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func log(_ category: LogCategory, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append("[\(category.rawValue)] \(message)")
    }
}
