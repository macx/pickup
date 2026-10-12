#if PICKUP_TESTING
import AppKit
import Foundation
import PickupCore

/// Scenario runner behind `-PickupTestScenario <name>`: owns the scripted phone, the fast clock and the
/// control channel the UI test uses to advance the script. Debug builds only (see `TestMode`).
///
/// Control channel: post a distributed notification named `dev.eiken.pickup.test.advance` (from the
/// XCUITest runner: `DistributedNotificationCenter.default().post(name: .init("dev.eiken.pickup.test.advance"), object: nil)`).
/// Each notification runs the next scripted step. `-PickupTestAutoAdvance <ms>` advances automatically.
@MainActor
final class TestHarness {
    static let shared = TestHarness()
    static let advanceNotification = Notification.Name("dev.eiken.pickup.test.advance")

    typealias Action = (ScriptedTransport) -> Void
    struct Script {
        /// Runs shortly after the link is up (e.g. the phone starts ringing).
        var initial: Action?
        /// One entry per `advance` notification.
        var steps: [Action] = []
    }

    enum Scenario: String, CaseIterable {
        case idle
        case incomingAccept = "incoming-accept"
        case incomingDecline = "incoming-decline"
        case incomingMissed = "incoming-missed"
        case incomingWithheld = "incoming-withheld"
        case outgoingAnswered = "outgoing-answered"
        case outgoingBusy = "outgoing-busy"
        case outgoingCancel = "outgoing-cancel"
        case callWaiting = "call-waiting"
        case linkLossResume = "link-loss-resume"
        case stressCycle = "stress-cycle"
    }

    let transport = ScriptedTransport()
    let scenario: Scenario
    let scheduler: Scheduler
    private let script: Script
    private var nextStep = 0
    private var observer: NSObjectProtocol?

    private init() {
        let name = TestMode.scenarioName ?? "idle"
        scenario = Scenario(rawValue: name) ?? .idle
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "PickupTestFastClock") {
            scheduler = FastScheduler(scale: defaults.string(forKey: "PickupTestClockScale").flatMap(Double.init) ?? 0.25)
        } else {
            scheduler = MainQueueScheduler()
        }
        script = Self.script(for: scenario)
    }

    /// Temporary log directory (never the real `~/Library/Logs/Pickup`).
    static var logDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pickup-test-logs", isDirectory: true)
    }

    /// Call once the engine has started the transport.
    func begin() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.advanceNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TestHarness.shared.advance() }
        }
        if let ms = UserDefaults.standard.string(forKey: "PickupTestAutoAdvance").flatMap(Int.init) {
            Task { @MainActor in
                while nextStep < script.steps.count {
                    try? await Task.sleep(for: .milliseconds(ms))
                    advance()
                }
            }
        }
        if scenario == .stressCycle {
            CallCycleSelfTest.run(cycles: 20)
        }
        if let initial = script.initial {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { initial(self.transport) } }
        }
    }

    func advance() {
        guard nextStep < script.steps.count else { return }
        let step = script.steps[nextStep]
        nextStep += 1
        step(transport)
    }

    // MARK: Scripts

    private static func script(for scenario: Scenario) -> Script {
        let ring: Action = { $0.ringIncoming(number: ScriptedTransport.jane) }
        switch scenario {
        case .idle, .stressCycle:
            return Script()
        case .incomingAccept:
            return Script(initial: ring, steps: [{ $0.remoteHangsUp() }])
        case .incomingDecline:
            return Script(initial: ring)
        case .incomingMissed:
            return Script(initial: ring, steps: [{ $0.setupEnded() }])
        case .incomingWithheld:
            return Script(initial: { $0.ringIncoming(number: nil) }, steps: [{ $0.remoteHangsUp() }])
        case .outgoingAnswered:
            return Script(steps: [{ $0.remoteAlerting() }, { $0.answered() }, { $0.remoteHangsUp() }])
        case .outgoingBusy:
            return Script(steps: [{ $0.remoteAlerting() }, { $0.busy() }])
        case .outgoingCancel:
            return Script(steps: [{ $0.remoteAlerting() }])
        case .callWaiting:
            return Script(initial: ring, steps: [{ $0.callWaiting(number: ScriptedTransport.john) }, { $0.remoteHangsUp() }])
        case .linkLossResume:
            return Script(initial: ring, steps: [{ $0.dropLink() }, { $0.resumeLink() }, { $0.remoteHangsUp() }])
        }
    }
}
#endif
