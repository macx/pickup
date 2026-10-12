import XCTest
import PickupCore
@testable import PickupBluetooth

/// Runs a complete call through the real `AppleHFPTransport` and `CallEngine` with canary phone
/// numbers, contact names, SMS text and DTMF digits, and asserts that none of them reaches the
/// log file or the string handed to the unified log. All data is invented.
@MainActor
final class LogCanaryTests: XCTestCase {
    private let canaryNumber = "+493091827364"
    private let canaryLocalNumber = "030918273645"
    private let canaryName = "Zorblax Quux"
    private let canarySecondName = "Jane Doe-Canary"
    private let canaryMessage = "canary-sms-body-5521"
    private let canaryPIN: [Character] = ["4", "7", "1", "1"]

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pickup-canary-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoPersonalDataReachesTheLogFileOrTheUnifiedLog() throws {
        let sink = Sink()
        let log = DiagnosticLog(directory: directory, prefix: "canary", subsystem: "dev.eiken.pickup.tests") { _, message in sink.add(message) }
        let clock = AppleHFPTransportTests.Clock()
        let registry = HandsFreeRegistry(now: { clock.now })
        var links: [AppleHFPTransportTests.FakeLink] = []
        var environment = AppleHFPTransport.Environment(
            makeLink: { _, _ in let link = AppleHFPTransportTests.FakeLink(); links.append(link); return link },
            observeDeviceConnects: { _ in nil }, installOutgoingTap: false, registry: registry
        )
        environment.assumeOutgoingTap = true
        let transport = AppleHFPTransport(
            deviceAddress: "aa-bb-cc-dd-ee-ff", log: log, scheduler: clock,
            policy: ReconnectPolicy(), timeouts: .init(), environment: environment
        )
        let engine = CallEngine(transport: transport, scheduler: clock, log: log)
        transport.connect()
        let link = try XCTUnwrap(links.last)
        link.isConnected = true
        transport.handsFree(link, connectedWithStatus: 0)
        XCTAssertEqual(transport.linkState, .connected)

        // Incoming call: number and name over every path the phone can use.
        transport.handsFree(link, indicator: .callSetup(.incoming))
        transport.handsFree(link, callerID: canaryNumber)
        transport.sentLine("AT+CLCC", detail: nil, channel: link.channel)
        transport.receivedLine("+CLCC: 1,1,4,0,0,\"\(canaryNumber)\",145,\"\(canaryName)\"", detail: nil)
        transport.receivedLine("OK", detail: nil)
        transport.handsFree(link, currentCall: HFPCall(index: 1, direction: .incoming, status: .incoming, number: canaryNumber, numberType: 145))
        transport.receivedLine("+CLIP: \"\(canaryNumber)\",145,,,\"\(canaryName)\"", detail: "RING")
        try engine.accept()
        transport.handsFree(link, indicator: .call(true))
        transport.handsFree(link, indicator: .callSetup(.none))
        clock.advance(by: 2)

        // Call waiting, SMS notification and subscriber lookups from a second contact.
        transport.receivedLine("+CCWA: \"\(canaryLocalNumber)\",129,1,,\"\(canarySecondName)\"", detail: nil)
        transport.receivedLine("+CMT: \"\(canaryNumber)\",\"\(canarySecondName)\",\"26/10/12,10:00:00+08\"", detail: nil)
        transport.receivedLine(canaryMessage, detail: nil)
        transport.receivedLine("+CMGR: \"REC UNREAD\",\"\(canaryNumber)\",\"\(canarySecondName)\"", detail: nil)
        transport.receivedLine("\(canaryMessage) line two", detail: nil)
        transport.receivedLine("OK", detail: nil)
        transport.receivedLine("+CNUM: ,\"\(canaryNumber)\",145,,4", detail: nil)

        // DTMF: a PIN typed during the call.
        for character in canaryPIN {
            try engine.sendDTMF(DTMFDigit(character)!)
            transport.sentLine("AT+VTS=\(character)", detail: nil, channel: link.channel)
            transport.receivedLine("OK", detail: nil)
        }

        // Hang up, then dial the canary number from the Mac and cancel.
        try engine.hangUp()
        transport.sentLine("AT+CHUP", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        transport.handsFree(link, indicator: .call(false))
        clock.advance(by: 10)
        try engine.dial(DialNumber(canaryLocalNumber)!)
        transport.sentLine("ATD\(canaryLocalNumber);", detail: nil, channel: link.channel)
        transport.receivedLine("OK", detail: nil)
        XCTAssertThrowsError(try engine.dial(DialNumber(canaryNumber)!)) // refused: a call is live
        transport.handsFree(link, indicator: .callSetup(.none))
        clock.advance(by: 10)
        link.isConnected = false
        transport.handsFree(link, disconnectedWithStatus: 0)
        clock.advance(by: 60)

        // Everything the app wrote.
        let fileURL = try XCTUnwrap(log.fileURL)
        let fileText = try String(contentsOf: fileURL, encoding: .utf8)
        let unified = sink.lines.joined(separator: "\n")
        XCTAssertGreaterThan(fileText.count, 500, "the scenario must have produced log output")
        XCTAssertEqual(fileText.split(separator: "\n").count, sink.lines.count, "file and unified log carry the same lines")
        XCTAssertTrue(fileText.contains("+CLCC") && fileText.contains("AT+VTS=<digit>"), "the scenario reached the AT log")

        XCTAssertTrue(fileText.contains("+49*******364"), "numbers appear only in abbreviated form")
        for (sinkName, text) in [("log file", fileText), ("unified log", unified)] {
            for secret in [canaryNumber, String(canaryNumber.dropFirst()), canaryLocalNumber, canaryName, canarySecondName,
                           canaryMessage, "Quux", "Zorblax", "sms-body", "4711"] {
                XCTAssertFalse(text.contains(secret), "\(sinkName) leaks \(secret)")
            }
            // Not even a long fragment of the digits: the redaction keeps at most 2 + 3 digits.
            for number in [canaryNumber, canaryLocalNumber] {
                let digits = Array(number.filter(\.isNumber))
                for start in 0...(digits.count - 5) {
                    let fragment = String(digits[start..<(start + 5)])
                    XCTAssertFalse(text.contains(fragment), "\(sinkName) leaks digits \(fragment) of a number")
                }
            }
            for digit in canaryPIN {
                XCTAssertFalse(text.contains("AT+VTS=\(digit)"), "\(sinkName) leaks a DTMF digit")
                XCTAssertFalse(text.contains("sendDTMF(\(digit))"), "\(sinkName) leaks a DTMF digit")
            }
        }
    }
}
