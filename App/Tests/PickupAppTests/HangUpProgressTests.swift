import XCTest
@testable import Pickup

final class HangUpProgressTests: XCTestCase {
    private let call = UUID()

    /// Regression: the phone rejects the hang-up asynchronously; End Call must be usable again at once,
    /// and the first attempt's timeout must not clear the progress of the retry.
    func testAsynchronousRejectionAllowsAnImmediateRetry() {
        var progress = HangUpProgress()
        let first = progress.start(call)
        XCTAssertTrue(progress.isEnding(call))
        progress.commandFailed()
        XCTAssertFalse(progress.isEnding(call), "a rejected hang-up re-enables End Call")
        let second = progress.start(call)
        progress.timedOut(attempt: first)
        XCTAssertTrue(progress.isEnding(call), "the first attempt's timeout must not clear the retry")
        progress.timedOut(attempt: second)
        XCTAssertFalse(progress.isEnding(call))
    }

    func testProgressBelongsToOneCall() {
        var progress = HangUpProgress()
        _ = progress.start(call)
        XCTAssertFalse(progress.isEnding(UUID()))
    }
}
