import XCTest
@testable import PickupCore

/// Seeded property tests for everything that parses untrusted input. Failures print the seed.
final class InputFuzzTests: XCTestCase {
    // Invented canaries; they must never survive sanitising/redaction.
    private let canaryNames = ["Jane Doe", "Zorblax Quux", "Müller-Lüdenscheidt", "李雷", "O'Brien, Pat"]

    // MARK: ATParser

    private static let atFragments = [
        "+CLIP:", "+CCWA:", "+CIEV:", "+CLCC:", "+CME ERROR:", "+CMS ERROR:", "RING", "OK", "ERROR", "BUSY",
        "NO CARRIER", "\"", "\"", ",", ",", ",", " ", "\r", "\n", "\t", "1", "2", "0", "145", "-1",
        "99999999999999999999999", "+4930000123", "Jane Doe", "(", ")", "\u{0}", "é", "😀", ";", ":", "=", "?",
    ]

    func testATParserNeverCrashesAndIsStableUnderWhitespace() {
        Fuzz.run("ATParser", iterations: 3000) { rng, seed in
            var line = ""
            for _ in 0..<rng.int(0...12) { line += rng.pick(Self.atFragments) }
            let parsed = ATParser.parse(line)
            let padded = ATParser.parse("  \(line)\r\n")
            XCTAssertEqual(parsed, padded, "surrounding whitespace changes the result \(Fuzz.context("ATParser", seed)) \(line.debugDescription)")
            // Final results and events are consistent.
            if let result = parsed.finalResult { XCTAssertFalse(result.isSuccess && parsed != .ok, Fuzz.context("ATParser", seed)) }
        }
    }

    func testATParserHandlesHugeAndBinaryLines() {
        var rng = SeededRandom(seed: 99)
        let huge = "+CLCC: " + String(repeating: "1,", count: 200_000)
        _ = ATParser.parse(huge)
        _ = ATParser.parse(String(repeating: "\"", count: 100_001))
        for _ in 0..<200 {
            let scalars = (0..<rng.int(0...64)).compactMap { _ in Unicode.Scalar(UInt32(rng.int(0...0x2FFFF))) }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            _ = ATParser.parse(String(view))
        }
    }

    func testValidCLCCLinesRoundTrip() {
        Fuzz.run("CLCC", iterations: 1000) { rng, seed in
            let index = rng.int(1...9)
            let direction = rng.int(0...1)
            let status = rng.int(0...6)
            let mode = rng.int(0...2)
            let multiparty = rng.int(0...1)
            let number = rng.chance(0.2) ? nil : (rng.chance(0.5) ? "+" : "") + rng.digits(rng.int(1...15))
            var line = "+CLCC: \(index),\(direction),\(status),\(mode),\(multiparty)"
            if let number {
                line += ",\"\(number)\",\(rng.pick([129, 145]))"
                if rng.chance(0.5) { line += ",\"\(rng.pick(canaryNames))\"" }
            }
            guard case .currentCall(let call) = ATParser.parse(line) else {
                return XCTFail("not parsed \(line) \(Fuzz.context("CLCC", seed))")
            }
            XCTAssertEqual(call.index, index, Fuzz.context("CLCC", seed))
            XCTAssertEqual(call.direction, direction == 1 ? .incoming : .outgoing, Fuzz.context("CLCC", seed))
            XCTAssertEqual(call.status.rawValue, status, Fuzz.context("CLCC", seed))
            XCTAssertEqual(call.number, number, Fuzz.context("CLCC", seed))
            XCTAssertEqual(call.isMultiparty, multiparty == 1, Fuzz.context("CLCC", seed))
        }
    }

    // MARK: ATLogSanitizer

    func testSanitizerNeverLetsContactNamesSMSBodiesOrDTMFThrough() {
        Fuzz.run("Sanitizer", iterations: 2000) { rng, seed in
            var sanitizer = ATLogSanitizer()
            let ctx = Fuzz.context("Sanitizer", seed)
            let name = rng.pick(canaryNames)
            let number = "+4930" + rng.digits(6)
            let body = "secret-body-\(rng.digits(6)) \(name)"
            let digit = rng.pick(Array("0123456789*#"))

            // Outgoing DTMF
            let sent = ATLogSanitizer.outgoing("AT+VTS=\(digit)")
            XCTAssertEqual(sent, "AT+VTS=<digit>", ctx)
            XCTAssertEqual(ATLogSanitizer.outgoing("at+vts=\(digit)"), "AT+VTS=<digit>", ctx)

            let lines: [(String, Bool)] = [
                ("+CLIP: \"\(number)\",145,,,\"\(name)\"", true),
                ("+CCWA: \"\(number)\",145,1,,\"\(name)\"", true),
                ("+CLCC: 1,1,4,0,0,\"\(number)\",145,\"\(name)\"", true),
                ("+CNUM: ,\"\(number)\",145,,\"\(name)\"", true),
                ("+CPBR: 1,\"\(number)\",145,\"\(name)\"", true),
            ]
            let (line, keepsNumber) = rng.pick(lines)
            let out = sanitizer.incoming(line)
            XCTAssertFalse(out.contains(name), "\(ctx) leaked name: \(out)")
            if keepsNumber { XCTAssertTrue(out.contains(number), "\(ctx) lost the number: \(out)") }

            // Message header + body, with random noise lines in between for the multi-line variants.
            let header = rng.pick(["+CMT: \"\(number)\",\"\(name)\",\"26/10/12,10:00:00+08\"", "+CMGR: \"REC UNREAD\",\"\(number)\",\"\(name)\""])
            XCTAssertFalse(sanitizer.incoming(header).contains(name), ctx)
            XCTAssertFalse(sanitizer.incoming(body).contains("secret-body"), "\(ctx) leaked body")
            XCTAssertFalse(sanitizer.incoming("").contains("secret-body"), ctx)
            let after = sanitizer.incoming("OK")
            XCTAssertEqual(after, "OK", "\(ctx) final result must pass through")
            XCTAssertEqual(sanitizer.incoming("+CIEV: 2,1"), "+CIEV: 2,1", "\(ctx) state leaked into the next line")
        }
    }

    func testSanitizerNeverCrashesOnRandomLines() {
        Fuzz.run("SanitizerRandom", iterations: 2000) { rng, seed in
            var sanitizer = ATLogSanitizer()
            for _ in 0..<rng.int(1...10) {
                var line = ""
                for _ in 0..<rng.int(0...10) { line += rng.pick(Self.atFragments + ["+CMT:", "+CMGL:", "+CMGR:", "AT+VTS="]) }
                _ = sanitizer.incoming(line)
                _ = ATLogSanitizer.outgoing(line)
            }
        }
    }

    // MARK: PhoneNumberRedaction

    func testRedactionHidesEveryGeneratedNumberInEveryContext() {
        let templates = [
            "%@", "ATD%@;", "tel:%@", "callto:%@", "number=%@", "dial %@ -> dial()", "<< +CLIP: \"%@\",145",
            "(%@)", "x%@x", "from %@, to %@", "'%@'", "call 1 incoming from %@ at 10:00", "%@\n",
        ]
        Fuzz.run("Redaction", iterations: 3000) { rng, seed in
            let ctx = Fuzz.context("Redaction", seed)
            let count = rng.int(5...15)
            let plus = rng.chance(0.5) ? "+" : ""
            var number = plus + rng.digits(count)
            let separated = rng.chance(0.4)
            if separated { // spaces, dashes and parentheses are the documented separators
                var spaced = ""
                for (offset, character) in number.enumerated() {
                    spaced.append(character)
                    if offset > 0, offset < number.count - 1, rng.chance(0.3) { spaced.append(rng.pick([" ", "-", ") ", " ("])) }
                }
                number = spaced
            }
            let template = rng.pick(templates)
            let input = template.replacingOccurrences(of: "%@", with: number)
            let output = PhoneNumberRedaction.redact(input)
            XCTAssertFalse(Self.hasDigitRun(output, atLeast: 5), "\(ctx) \(input.debugDescription) -> \(output.debugDescription)")
            XCTAssertLessThanOrEqual(output.count, input.count, ctx)
            XCTAssertEqual(PhoneNumberRedaction.redact(output), output, "\(ctx) not idempotent: \(output)")
        }
    }

    func testRedactionLeavesTextWithoutNumbersAlone() {
        let words = ["call", "ended", "link", "state", "[STATE]", "->", "ringing", "id=7", "x2", "0", "12", "999", "1234", "A1B2", "ok:", "3,4"]
        Fuzz.run("RedactionPlain", iterations: 1500) { rng, seed in
            let text = (0..<rng.int(1...8)).map { _ in rng.pick(words) }.joined(separator: " | ") // plain spaces would merge digit groups into a number (accepted over-redaction)
            XCTAssertEqual(PhoneNumberRedaction.redact(text), text, Fuzz.context("RedactionPlain", seed))
        }
    }

    func testRedactionKeepsBluetoothAddressesHexValuesAndPaths() {
        Fuzz.run("RedactionProtected", iterations: 1000) { rng, seed in
            let hex = Array("0123456789abcdef")
            let separator = rng.pick(["-", ":"])
            let address = (0..<6).map { _ in rng.string(from: hex, length: 2) }.joined(separator: separator)
            let text = "device \(address) status 0x\(rng.string(from: hex, length: 8)) file /tmp/pickup-\(rng.digits(8)).log"
            XCTAssertEqual(PhoneNumberRedaction.redact(text), text, Fuzz.context("RedactionProtected", seed))
        }
    }

    /// Known gap (reported, not fixed): only space, `-`, `(`, `)` are separators inside a number.
    /// With `.`, `_`, tab, NBSP or an en dash the tail is masked but the country/area prefix stays
    /// visible, and a dotted number with groups of fewer than 5 digits is not masked at all. The app
    /// never logs raw typed text (it logs the normalised `DialNumber`) and phones send plain digits,
    /// so this only matters if a raw string ever reaches the log. Recorded behaviour, not a
    /// requirement: if this test starts failing the gap was closed (good, update the expectations).
    func testRedactionGapForExoticSeparatorsIsRecorded() {
        XCTAssertEqual(PhoneNumberRedaction.redact("raw 030.000.1234"), "raw 030.000.1234")
        XCTAssertEqual(PhoneNumberRedaction.redact("+49.30.0001234"), "+49.30.*****34")
        XCTAssertEqual(PhoneNumberRedaction.redact("x 030\u{2013}0001234"), "x 030\u{2013}*****34")
        XCTAssertEqual(PhoneNumberRedaction.redact("a +49\u{00A0}30\u{00A0}0001234"), "a +49\u{00A0}30\u{00A0}*****34")
    }

    private static func hasDigitRun(_ text: String, atLeast length: Int) -> Bool {
        var run = 0
        for character in text {
            if ("0"..."9").contains(character) { run += 1; if run >= length { return true } } else { run = 0 }
        }
        return false
    }

    // MARK: DialNumber

    private static let dialAlphabet = Array("0123456789+*#-. ()/;,\r\n\t%abcdefABCDEF\u{00A0}\u{2013}٣１")

    func testDialNumberOnlyEverProducesASafeDialString() {
        Fuzz.run("DialNumber", iterations: 5000) { rng, seed in
            let raw = rng.string(from: Self.dialAlphabet, length: rng.int(0...40))
            guard let number = DialNumber(raw) else { return }
            let ctx = "\(Fuzz.context("DialNumber", seed)) \(raw.debugDescription) -> \(number.value.debugDescription)"
            XCTAssertTrue(number.value.allSatisfy { "+*#0123456789".contains($0) }, ctx)
            XCTAssertFalse(number.value.dropFirst().contains("+"), ctx)
            XCTAssertLessThanOrEqual(number.value.count, DialNumber.maximumLength, ctx)
            XCTAssertTrue(number.value.contains { $0.isNumber || $0 == "*" || $0 == "#" }, ctx)
            XCTAssertEqual(number.isServiceCode, number.value.contains("*") || number.value.contains("#"), ctx)
            // The AT command built from it has exactly one command and ends in the single terminator.
            let command = "ATD\(number.value);"
            XCTAssertEqual(command.filter { $0 == ";" }.count, 1, ctx)
            XCTAssertFalse(command.contains("\r") || command.contains("\n"), ctx)
        }
    }

    func testInjectionPayloadsNeverBecomeDialNumbers() {
        let payloads = [
            "123;ATD999", "123\r\nAT+CHUP", "123\rATA", "123\nATH", "+49;+49", "123;", ";123", "1\u{0}23",
            "123%0D", "123%0d%0aAT", "12%3B3", "%3B", "AT+CHUP", "ATD123", "123 AT", "1,2", "1p2", "٣٣٣", "１２３", "123\u{2028}456",
        ]
        for payload in payloads {
            if let number = DialNumber(payload) {
                // Only harmless normalisation may succeed (trailing/leading whitespace).
                XCTAssertTrue(number.value.allSatisfy { "+*#0123456789".contains($0) }, payload.debugDescription)
            }
            for scheme in ["tel", "TEL", "callto", "telprompt"] {
                for variant in [payload, payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? payload] {
                    guard let url = URL(string: "\(scheme):\(variant)"), let number = DialNumber(url: url) else { continue }
                    XCTAssertTrue(number.value.allSatisfy { "+*#0123456789".contains($0) }, "\(scheme):\(variant) -> \(number.value)")
                    XCTAssertFalse(number.value.contains(";"), "\(scheme):\(variant)")
                }
            }
        }
        // Nothing after ';' or '?' in a URL may reach the number: RFC 3966 parameters are dropped.
        XCTAssertEqual(DialNumber(url: URL(string: "tel:+4930000123;phone-context=%0D%0AAT+CHUP")!)?.value, "+4930000123")
        XCTAssertEqual(DialNumber(url: URL(string: "tel:+4930000123?x=1;ATD999")!)?.value, "+4930000123")
        XCTAssertNil(DialNumber(url: URL(string: "tel:+49%3B30")!), "%3B decodes to ';' which is rejected")
        XCTAssertNil(DialNumber(url: URL(string: "tel:12%0D%0A34")!), "CR LF inside is rejected")
        XCTAssertNil(DialNumber(url: URL(string: "https://example.com/+4930000123")!))
        XCTAssertNil(DialNumber(url: URL(string: "sms:+4930000123")!))
    }

    func testDialNumberFromRandomURLsIsSafeAndServiceCodesAreFlagged() {
        let pieces = ["+49", "30", "000123", "%23", "%2A", "*", "#", ";", "?", "=", "%3B", "%0D", "%0A", "%20", "-", ".", "/", "//", "%2B", "+", "phone-context=", "x"]
        Fuzz.run("DialURL", iterations: 4000) { rng, seed in
            let scheme = rng.pick(["tel", "TEL", "callto", "telprompt", "sms", "http"])
            let body = (0..<rng.int(0...8)).map { _ in rng.pick(pieces) }.joined()
            guard let url = URL(string: "\(scheme):\(body)"), let number = DialNumber(url: url) else { return }
            let ctx = "\(Fuzz.context("DialURL", seed)) \(url.absoluteString)"
            XCTAssertTrue(["tel", "callto", "telprompt"].contains(scheme.lowercased()), "wrong scheme accepted \(ctx)")
            XCTAssertTrue(number.value.allSatisfy { "+*#0123456789".contains($0) }, ctx)
            if body.contains("%23") || body.contains("%2A") || body.contains("*") {
                // A star or hash that survived before the first ';' or '?' makes it a service code.
                let head = body.prefix { $0 != ";" && $0 != "?" }
                if head.contains("%23") || head.contains("%2A") || head.contains("*") || head.contains("#") {
                    XCTAssertTrue(number.isServiceCode, ctx)
                }
            }
        }
    }

    // MARK: ATExchangeTracker

    func testTrackerNeverLosesTrackOfACommand() {
        let commands = ["AT+CLCC", "ATA", "AT+CHUP", "ATD+4930000123;", "AT+VTS=5", "AT+CIND?", "AT+CMER=3,0,0,1", "AT+CLIP=1", "AT+BRSF=116"]
        let replies = ["OK", "ERROR", "+CME ERROR: 30", "+CMS ERROR: 500", "BUSY", "NO CARRIER", "+CLCC: 1,1,4,0,0,\"+4930000123\",145",
                       "+CIEV: 2,1", "RING", "+CLIP: \"+4930000123\",145", "+BRSF: 3968", "garbage", ""]
        Fuzz.run("Tracker", iterations: 1500) { rng, seed in
            let ctx = Fuzz.context("Tracker", seed)
            var tracker = ATExchangeTracker(responseTimeout: 5)
            var time = Date(timeIntervalSince1970: 1_800_000_000)
            var sent: [HFPCommand] = []
            var completed: [HFPCommand] = []
            var discarded = 0
            var resetDropped = 0
            func absorb(_ outputs: [ATExchangeTracker.Output]) {
                for output in outputs {
                    switch output {
                    case .completed(let exchange): completed.append(exchange.command)
                    case .discarded: discarded += 1
                    case .unsolicited, .response: break
                    }
                }
                XCTAssertLessThanOrEqual(tracker.pendingCount, ATExchangeTracker.maximumPending, ctx)
            }
            for _ in 0..<rng.int(1...40) {
                time.addTimeInterval(rng.pick([0, 0.01, 0.5, 1, 4, 6, 30]))
                switch rng.int(0...9) {
                case 0...3:
                    let command = rng.pick(commands)
                    sent.append(HFPCommand(atCommand: command))
                    absorb(tracker.outgoing(command, at: time))
                case 4...7:
                    absorb(tracker.incoming(rng.pick(replies), at: time))
                case 8:
                    absorb(tracker.writeFailed())
                default:
                    resetDropped += tracker.pendingCount
                    tracker.reset()
                }
            }
            // Conservation: every sent command was completed, discarded, dropped by reset, or is still pending.
            XCTAssertEqual(sent.count, completed.count + discarded + resetDropped + tracker.pendingCount, ctx)
            // Completions keep the order of sending.
            var cursor = 0
            for command in completed {
                guard let found = sent[cursor...].firstIndex(of: command) else { return XCTFail("completion out of order \(ctx)") }
                cursor = found + 1
            }
        }
    }
}
