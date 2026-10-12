import XCTest
@testable import PickupCore

@MainActor
final class ReconnectControllerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var attempts = 0
    private var controller: ReconnectController!

    override func setUp() async throws {
        scheduler = ManualScheduler()
        attempts = 0
        controller = ReconnectController(scheduler: scheduler) { [unowned self] in
            self.attempts += 1
        }
    }

    func testPolicyBacksOffExponentiallyUpToTheCap() {
        let policy = ReconnectPolicy()
        XCTAssertEqual((1...8).map { policy.delay(afterFailures: $0) }, [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(policy.delay(afterFailures: 0), 0)
        XCTAssertEqual(policy.delay(afterFailures: 10_000), 60)
    }

    func testStartAttemptsImmediately() {
        controller.start()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.state, .attempting)
    }

    func testFailuresAreRetriedWithBackoff() {
        controller.start()
        controller.linkFailed()
        XCTAssertEqual(controller.state, .waiting(until: scheduler.now.addingTimeInterval(2)))
        scheduler.advance(by: 1.9)
        XCTAssertEqual(attempts, 1)
        scheduler.advance(by: 0.1)
        XCTAssertEqual(attempts, 2)

        controller.linkFailed()
        scheduler.advance(by: 3.9)
        XCTAssertEqual(attempts, 2)
        scheduler.advance(by: 0.1)
        XCTAssertEqual(attempts, 3)
    }

    func testDropAfterSuccessStartsAgainWithShortDelay() {
        controller.start()
        controller.linkFailed()
        scheduler.advance(by: 2)
        controller.linkFailed()
        scheduler.advance(by: 4)
        controller.linkEstablished()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.failures, 0)

        controller.linkFailed() // link dropped
        scheduler.advance(by: 2)
        XCTAssertEqual(attempts, 4)
    }

    func testStopCancelsPendingAttempt() {
        controller.start()
        controller.linkFailed()
        controller.stop()
        scheduler.advance(by: 100)
        XCTAssertEqual(attempts, 1)
        controller.linkFailed() // e.g. the disconnected callback after a user disconnect
        scheduler.advance(by: 100)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testSleepSuspendsAndWakeRetriesImmediately() {
        controller.start()
        controller.linkEstablished()
        controller.suspend()
        controller.linkFailed() // the disconnect caused by prepareForSleep
        scheduler.advance(by: 100)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.state, .suspended)

        controller.resumeAfterSleep()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(controller.failures, 0)
    }

    func testWakeDoesNotReconnectAfterUserDisconnect() {
        controller.start()
        controller.linkEstablished()
        controller.stop()
        controller.resumeAfterSleep()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testWakeWhileWaitingRetriesNow() {
        controller.start()
        controller.linkFailed()
        controller.linkFailed() // ignored
        controller.resumeAfterSleep()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(controller.failures, 0)
    }

    func testWakeWhileConnectedDoesNothing() {
        controller.start()
        controller.linkEstablished()
        controller.resumeAfterSleep()
        XCTAssertEqual(attempts, 1)
    }

    func testResumeWhileConnectedDoesNothing() {
        controller.start()
        controller.linkEstablished()
        controller.resume()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.state, .connected)
    }

    func testDeviceAppearingSkipsTheWait() {
        controller.start()
        controller.linkFailed()
        controller.linkFailed() // ignored, already waiting
        controller.deviceAppeared()
        XCTAssertEqual(attempts, 2)
        scheduler.advance(by: 100)
        XCTAssertEqual(attempts, 2, "the cancelled timer must not fire")
    }

    func testStateChangesAreReported() {
        var states: [ReconnectController.State] = []
        controller.onStateChange = { states.append($0) }
        controller.start()
        controller.linkFailed()
        scheduler.advance(by: 2)
        controller.linkEstablished()
        XCTAssertEqual(states.count, 4)
        XCTAssertEqual(states.first, .attempting)
        XCTAssertEqual(states.last, .connected)
    }
}
