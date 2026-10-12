import XCTest
@testable import PickupCore

final class DialNumberTests: XCTestCase {
    func testNormalisesSeparators() {
        XCTAssertEqual(DialNumber("+49 (30) 000-123")?.value, "+4930000123")
        XCTAssertEqual(DialNumber(" 030/000.123 ")?.value, "030000123")
        XCTAssertEqual(DialNumber("+49\u{00A0}30\u{00A0}000123")?.value, "+4930000123")
    }

    func testServiceCodes() {
        XCTAssertEqual(DialNumber("*#06#")?.value, "*#06#")
    }

    func testRejectsInjectionAndGarbage() {
        XCTAssertNil(DialNumber("123;ATA"))
        XCTAssertNil(DialNumber("123\rAT+CHUP"))
        XCTAssertNil(DialNumber("1-800-FLOWERS"))
        XCTAssertNil(DialNumber("49+30"))
        XCTAssertNil(DialNumber("++49"))
        XCTAssertNil(DialNumber(""))
        XCTAssertNil(DialNumber("+"))
        XCTAssertNil(DialNumber("٣٠٠"), "non-ASCII digits")
        XCTAssertNil(DialNumber(String(repeating: "1", count: DialNumber.maximumLength + 1)))
    }

    func testTelURLs() {
        XCTAssertEqual(DialNumber(url: URL(string: "tel:+49-30-000123")!)?.value, "+4930000123")
        XCTAssertEqual(DialNumber(url: URL(string: "tel:030000123;phone-context=example.com")!)?.value, "030000123")
        XCTAssertEqual(DialNumber(url: URL(string: "tel:%2B4930000123")!)?.value, "+4930000123")
        XCTAssertEqual(DialNumber(url: URL(string: "callto://+4930000123")!)?.value, "+4930000123")
        XCTAssertEqual(DialNumber(url: URL(string: "callto:030%20000%20123")!)?.value, "030000123")
        XCTAssertNil(DialNumber(url: URL(string: "https://example.com/030000123")!))
        XCTAssertNil(DialNumber(url: URL(string: "tel:123%3BATA")!))
    }

    func testServiceCodesFromLinksAreFlagged() {
        let forwarding = DialNumber(url: URL(string: "tel:**21*0300000123%23")!)
        XCTAssertEqual(forwarding?.value, "**21*0300000123#")
        XCTAssertEqual(forwarding?.isServiceCode, true)
        XCTAssertEqual(DialNumber(url: URL(string: "tel:*%2306%23")!)?.isServiceCode, true)
        XCTAssertEqual(DialNumber(url: URL(string: "tel:+4930000123")!)?.isServiceCode, false)
        XCTAssertEqual(DialNumber("+49 30 000123")?.isServiceCode, false)
    }

    func testDTMFDigits() {
        XCTAssertEqual(DTMFDigit("5")?.description, "5")
        XCTAssertEqual(DTMFDigit("a")?.description, "A")
        XCTAssertEqual(DTMFDigit("#")?.description, "#")
        XCTAssertNil(DTMFDigit("E"))
        XCTAssertNil(DTMFDigit(";"))
    }
}
