import XCTest
@testable import PickupCore

final class ATLogSanitizerTests: XCTestCase {
    func testCLIPContactNameIsBlanked() {
        // Shape from the phase 0 headset run (name replaced).
        var sanitizer = ATLogSanitizer()
        XCTAssertEqual(
            sanitizer.incoming(#"+CLIP: "+49*******515",145,,,"Jane Doe""#),
            #"+CLIP: "+49*******515",145,,,"""#
        )
    }

    func testCLCCAndCCWAAlphaAreBlanked() {
        var sanitizer = ATLogSanitizer()
        XCTAssertEqual(
            sanitizer.incoming(#"+CLCC: 1,1,5,0,0,"030000123",129,"Doe, Jane""#),
            #"+CLCC: 1,1,5,0,0,"030000123",129,"""#
        )
        XCTAssertEqual(
            sanitizer.incoming(#"+CCWA: "030000123",129,1,"Jane Doe""#),
            #"+CCWA: "030000123",129,1,"""#
        )
    }

    func testCNUMKeepsOnlyTheNumber() {
        var sanitizer = ATLogSanitizer()
        XCTAssertEqual(sanitizer.incoming(#"+CNUM: "Me","+4930000123",145,,4"#), #"+CNUM: "","+4930000123",145,,4"#)
    }

    func testLinesWithoutNamesAreUnchanged() {
        var sanitizer = ATLogSanitizer()
        for line in [#"+CLIP: "+4930000123",145"#, "+CIEV: 2,1", "RING", "OK", #"+CLCC: 1,1,4,0,0,"+49*******515",145"#] {
            XCTAssertEqual(sanitizer.incoming(line), line)
        }
    }

    func testCMTBodyIsRemoved() {
        var sanitizer = ATLogSanitizer()
        XCTAssertEqual(sanitizer.incoming(#"+CMT: "+4930000123","Jane Doe","26/10/11,11:00:00+08""#),
                       #"+CMT: "+4930000123","","""#)
        XCTAssertEqual(sanitizer.incoming("Meet me at 5, PIN is 1234"), ATLogSanitizer.removedBody)
        XCTAssertEqual(sanitizer.incoming("+CIEV: 2,1"), "+CIEV: 2,1", "only one body line for +CMT")
    }

    func testCMGRBodyIsRemovedUntilTheFinalResult() {
        var sanitizer = ATLogSanitizer()
        _ = sanitizer.incoming(#"+CMGR: "REC READ","+4930000123",,"26/10/11,11:00:00+08""#)
        XCTAssertEqual(sanitizer.incoming("first line"), ATLogSanitizer.removedBody)
        XCTAssertEqual(sanitizer.incoming("+second line"), ATLogSanitizer.removedBody)
        XCTAssertEqual(sanitizer.incoming("OK"), "OK")
        XCTAssertEqual(sanitizer.incoming("+CIEV: 2,1"), "+CIEV: 2,1")
    }

    func testDTMFDigitIsHidden() {
        XCTAssertEqual(ATLogSanitizer.outgoing("AT+VTS=1"), "AT+VTS=<digit>")
        XCTAssertEqual(ATLogSanitizer.outgoing("AT+CLCC"), "AT+CLCC")
    }

    func testFullPipelineWithRedaction() {
        var sanitizer = ATLogSanitizer()
        let line = PhoneNumberRedaction.redact(sanitizer.incoming(#"+CLIP: "+4930000123",145,,,"Jane Doe""#))
        XCTAssertEqual(line, #"+CLIP: "+49*****123",145,,,"""#)
    }
}
