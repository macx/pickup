import XCTest
@testable import PickupCore

/// A scripted Pixel-like phone around `MockHFPTransport` and `CallEngine`, for scenario tests.
///
/// The phone behaves like the real Pixel it was recorded from: it sends `callsetup` indicators (no
/// `RING`/`+CLIP` without a headset) and answers `AT+CLCC` only when the test calls `answerCallList()`.
/// All numbers and names are invented.
@MainActor
final class ScriptedPhone {
    nonisolated static let jane = "+4930000123"
    nonisolated static let john = "+4940000456"

    let transport = MockHFPTransport()
    let scheduler = ManualScheduler()
    let engine: CallEngine
    private(set) var finished: [CallInfo] = []
    /// What `AT+CLCC` currently returns.
    var callList: [HFPCall] = []

    init(supportsAudio: Bool, takeCallsOnMac: Bool = false, configuration: CallEngine.Configuration = .init(), log: DiagnosticLogging = NullDiagnosticLog()) {
        transport.supportsAudio = supportsAudio
        engine = CallEngine(transport: transport, scheduler: scheduler, log: log, configuration: configuration)
        engine.takeCallsOnMac = takeCallsOnMac
        engine.onCallFinished = { [unowned self] in self.finished.append($0) }
        transport.bringUp()
        transport.clearCommands()
    }

    // MARK: Phone side

    func ringIncoming(number: String? = ScriptedPhone.jane) {
        callList = [HFPCall(index: 1, direction: .incoming, status: .incoming, number: number, numberType: 145)]
        transport.emit(.callSetup(.incoming))
    }

    /// Replies to the pending `AT+CLCC` with the current `callList`.
    func answerCallList() {
        transport.emit(.currentCalls(callList))
        transport.emit(.commandCompleted(.currentCalls, .ok))
    }

    func answered() {
        callList = callList.map { var c = $0; c.status = .active; return c }
        transport.emit(.call(true))
        transport.emit(.callSetup(.none))
    }

    func setupEnded() { transport.emit(.callSetup(.none)) }
    func remoteHangsUp() { callList = []; transport.emit(.call(false)) }

    func startOutgoing(number: String = ScriptedPhone.jane) {
        callList = [HFPCall(index: 1, direction: .outgoing, status: .dialing, number: number, numberType: 145)]
        transport.emit(.commandCompleted(.dial, .ok))
        transport.emit(.callSetup(.outgoing))
    }

    func remoteAlerting() { transport.emit(.callSetup(.remoteAlerting)) }

    func dropLink() { transport.emit(.linkStateChanged(.disconnected)) }

    // MARK: Helpers

    func advance(_ seconds: TimeInterval) { scheduler.advance(by: seconds) }

    /// Runs the grace period of `callsetup=0` and the ended display time.
    func settle() { scheduler.advance(by: engine.configuration.endedDisplayDuration + engine.configuration.setupEndGrace + 1) }

    var commands: [MockHFPTransport.Command] { transport.commands }
    /// Commands without the audio watchdog's `transferAudioToPhone` (audio on the Mac, SCO never opened).
    var userCommands: [MockHFPTransport.Command] { commands.filter { $0 != .transferAudioToPhone } }

    /// Commands the engine may send on its own (no user action): call list requests and audio hand-backs.
    static let autonomous: Set<String> = ["requestCurrentCalls", "transferAudioToPhone"]

    /// Nothing but `AT+CLCC` and audio hand-backs may have been sent unless the test asked for it:
    /// the engine never dials, accepts, hangs up or sends DTMF by itself.
    func assertNoSpontaneousCommands(allowingLifecycle: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let lifecycle: Set<String> = allowingLifecycle ? ["prepareForSleep", "resumeAfterSleep", "connect", "disconnect", "reconnect"] : []
        let unexpected = commands.filter { !Self.autonomous.contains(Self.name(of: $0)) && !lifecycle.contains(Self.name(of: $0)) }
        XCTAssertTrue(unexpected.isEmpty, "unrequested commands: \(unexpected)", file: file, line: line)
    }

    static func name(of command: MockHFPTransport.Command) -> String {
        switch command {
        case .requestCurrentCalls: return "requestCurrentCalls"
        case .transferAudioToPhone: return "transferAudioToPhone"
        default: return "\(command)"
        }
    }
}
