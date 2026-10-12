import XCTest
@testable import PickupCore

final class ATParserTests: XCTestCase {
    func testRing() {
        XCTAssertEqual(ATParser.parse("RING\r\n"), .ring)
    }

    func testCallerID() {
        XCTAssertEqual(ATParser.parse("+CLIP: \"+4955500123\",145"), .callerID(number: "+4955500123"))
    }

    func testIndicator() {
        XCTAssertEqual(ATParser.parse("+CIEV: 2,1"), .indicator(index: 2, value: 1))
    }

    func testOKAndError() {
        XCTAssertEqual(ATParser.parse("OK"), .ok)
        XCTAssertEqual(ATParser.parse("ERROR"), .error)
    }

    func testUnknown() {
        XCTAssertEqual(ATParser.parse("+BRSF: 871"), .unknown("+BRSF: 871"))
    }

    func testCLCCFromPixel() {
        XCTAssertEqual(
            ATParser.parse(#"+CLCC: 1,1,4,0,0,"+49*******515",145"#),
            .currentCall(HFPCall(index: 1, direction: .incoming, status: .incoming, number: "+49*******515", numberType: 145))
        )
    }

    func testCLCCWithoutNumber() {
        XCTAssertEqual(
            ATParser.parse("+CLCC: 2,0,0,0,1"),
            .currentCall(HFPCall(index: 2, direction: .outgoing, status: .active, isMultiparty: true))
        )
    }

    func testCLCCWithQuotedAlphaContainingComma() {
        let call = ATParser.parseCLCC(#"+CLCC: 1,1,5,0,0,"030000123",129,"Doe, Jane""#)
        XCTAssertEqual(call?.status, .waiting)
        XCTAssertEqual(call?.number, "030000123")
        XCTAssertEqual(call?.numberType, 129)
    }

    func testMalformedCLCCIsUnknown() {
        XCTAssertEqual(ATParser.parse("+CLCC: 1,1"), .unknown("+CLCC: 1,1"))
        XCTAssertEqual(ATParser.parse("+CLCC: 1,1,9,0,0"), .unknown("+CLCC: 1,1,9,0,0"))
    }

    func testCallWaiting() {
        XCTAssertEqual(ATParser.parse(#"+CCWA: "+4930000123",145,1"#), .callWaiting(number: "+4930000123"))
    }

    func testFinalResults() {
        XCTAssertEqual(ATParser.parse("+CME ERROR: 30"), .cmeError(30))
        XCTAssertEqual(ATParser.parse("NO CARRIER"), .callFailure("NO CARRIER"))
        XCTAssertEqual(ATParser.parse("BUSY").finalResult, .callFailure("BUSY"))
        XCTAssertNil(ATParser.parse("+CIEV: 2,1").finalResult)
    }
}
