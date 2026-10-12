import XCTest
@testable import PickupCore

/// The engine's own logging (events, commands, call list) with canary numbers and DTMF digits,
/// written through the real `DiagnosticLog` (file plus the unified-log sink). The raw AT path with
/// contact names is covered in `PickupBluetoothTests/LogCanaryTests`.
@MainActor
final class LogCanaryCoreTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return storage.joined(separator: "\n") }
    }

    func testEngineLogsNeverContainNumbersOrDTMF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pickup-canary-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = Sink()
        let log = DiagnosticLog(directory: directory, prefix: "canary", subsystem: "dev.eiken.pickup.tests") { _, message in sink.add(message) }
        let canaryIncoming = "+493091827364"
        let canaryOutgoing = "+12025550173"
        let canaryServiceCode = "**21*0309182736#"

        for (audio, take) in [(false, false), (true, false), (true, true)] {
            let phone = ScriptedPhone(supportsAudio: audio, takeCallsOnMac: take, log: log)
            phone.ringIncoming(number: canaryIncoming)
            phone.answerCallList()
            phone.transport.emit(.callerID(canaryIncoming))
            try phone.engine.accept()
            phone.answered()
            for digit in "4711" { try phone.engine.sendDTMF(DTMFDigit(digit)!) }
            phone.transport.emit(.callSetup(.incoming))
            phone.transport.emit(.callWaiting(canaryOutgoing))
            phone.remoteHangsUp()
            phone.settle()
            phone.dropLink()
            phone.transport.bringUp()
            try phone.engine.dial(DialNumber(canaryOutgoing)!)
            phone.startOutgoing(number: canaryOutgoing)
            phone.transport.emit(.currentCalls([HFPCall(index: 1, direction: .outgoing, status: .active, number: canaryOutgoing)]))
            try phone.engine.hangUp()
            phone.settle()
            XCTAssertThrowsError(try phone.engine.dial(DialNumber(canaryServiceCode)!))
        }

        let fileText = try String(contentsOf: XCTUnwrap(log.fileURL), encoding: .utf8)
        XCTAssertTrue(fileText.contains("+49*******364"), "the scenario logged the incoming number in abbreviated form")
        XCTAssertTrue(fileText.contains("dtmf -> sendDTMF()"))
        for (sinkName, text) in [("log file", fileText), ("unified log", sink.text)] {
            for secret in [canaryIncoming, String(canaryIncoming.dropFirst()), canaryOutgoing, String(canaryOutgoing.dropFirst()),
                           "9182736", "2025550", "4711", "sendDTMF(4)", "sendDTMF(7)", "AT+VTS=4"] {
                XCTAssertFalse(text.contains(secret), "\(sinkName) leaks \(secret)")
            }
        }
    }
}
