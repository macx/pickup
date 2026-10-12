import XCTest
@testable import PickupCore

final class PhoneNumberRedactionTests: XCTestCase {
    func testInternationalNumberKeepsPrefixAndLastThreeDigits() {
        XCTAssertEqual(PhoneNumberRedaction.redact("+4955500123"), "+49*****123")
    }

    func testNationalNumber() {
        XCTAssertEqual(PhoneNumberRedaction.redact("015112345678"), "01*******678")
    }

    func testShortNumberKeepsLastTwoDigits() {
        XCTAssertEqual(PhoneNumberRedaction.redact("call 12345 now"), "call ***45 now")
    }

    func testNumberWithSeparators() {
        XCTAssertEqual(PhoneNumberRedaction.redact("dial +49 (555) 00-123"), "dial +49*****123")
    }

    func testCLIPLine() {
        XCTAssertEqual(
            PhoneNumberRedaction.redact("<< +CLIP: \"+4955500123\",145"),
            "<< +CLIP: \"+49*****123\",145"
        )
    }

    func testCLCCLine() {
        XCTAssertEqual(
            PhoneNumberRedaction.redact("+CLCC: 1,1,4,0,0,\"015112345678\",129"),
            "+CLCC: 1,1,4,0,0,\"01*******678\",129"
        )
    }

    func testLeavesShortValuesAlone() {
        let line = "+CIEV: 2,1 +CIND: 1,0,0,4,0,5,0 dtmf 1234"
        XCTAssertEqual(PhoneNumberRedaction.redact(line), line)
    }

    func testLeavesHexAndBluetoothAddressesAlone() {
        let line = "status=0xE00002BC address=a4-c3-f0-12-34-56 other=a4:c3:f0:12:34:56"
        XCTAssertEqual(PhoneNumberRedaction.redact(line), line)
    }

    func testLeavesTextWithoutNumbersAlone() {
        XCTAssertEqual(PhoneNumberRedaction.redact("RING"), "RING")
        XCTAssertEqual(PhoneNumberRedaction.redact(""), "")
    }

    func testNumberGluedToATD() {
        XCTAssertEqual(PhoneNumberRedaction.redact("> ATD015112345678;"), "> ATD01*******678;")
    }

    func testInternationalNumberGluedToATD() {
        XCTAssertEqual(PhoneNumberRedaction.redact(">> ATD+4917012345678;"), ">> ATD+49********678;")
    }

    func testTelAndCalltoURLs() {
        XCTAssertEqual(PhoneNumberRedaction.redact("open tel:+4930123456"), "open tel:+49*****456")
        XCTAssertEqual(PhoneNumberRedaction.redact("callto:015112345678"), "callto:01*******678")
    }

    func testKeyValueNumber() {
        XCTAssertEqual(
            PhoneNumberRedaction.redact("incomingCallFrom number=+4955500123"),
            "incomingCallFrom number=+49*****123"
        )
    }

    func testLeavesHexPairsAndPathsAlone() {
        let line = "agSDPFeatures=0x002f log file /Users/x/Library/Logs/Pickup/apple-hfp-20261011-102516.log"
        XCTAssertEqual(PhoneNumberRedaction.redact(line), line)
    }

    func testMultipleNumbers() {
        XCTAssertEqual(
            PhoneNumberRedaction.redact("from 0301234567 to +4917012345678"),
            "from 03*****567 to +49********678"
        )
    }
}
