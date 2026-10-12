import XCTest
@testable import Pickup

final class PhoneNumberFormatTests: XCTestCase {
    func testGermanMobileIsGrouped() {
        XCTAssertEqual(PhoneNumberFormat.display("01701234567", region: "DE"), "0170 1234567")
        XCTAssertEqual(PhoneNumberFormat.display("0151 2345678", region: "DE"), "0151 2345678")
    }

    func testGermanBigCityLandlineIsGrouped() {
        XCTAssertEqual(PhoneNumberFormat.display("0300000123", region: "DE"), "030 0000123")
        XCTAssertEqual(PhoneNumberFormat.display("08912345678", region: "DE"), "089 12345678")
        XCTAssertEqual(PhoneNumberFormat.display("069 1234567", region: "DE"), "069 1234567")
    }

    func testOtherGermanLandlineIsNotRegrouped() {
        XCTAssertEqual(PhoneNumberFormat.display("02304123456", region: "DE"), "02304123456")
        XCTAssertEqual(PhoneNumberFormat.display("0301234567", region: "AT"), "0301234567")
    }

    func testGermanInternationalGrouping() {
        XCTAssertEqual(PhoneNumberFormat.display("+491700000123", region: "DE"), "+49 170 0000123")
        XCTAssertEqual(PhoneNumberFormat.display("+491710000456", region: "US"), "+49 171 0000456")
        XCTAssertEqual(PhoneNumberFormat.display("+49 1512 3456789", region: "DE"), "+49 151 23456789")
        XCTAssertEqual(PhoneNumberFormat.display("+49300000123", region: "DE"), "+49 30 0000123")
        XCTAssertEqual(PhoneNumberFormat.display("+49 40 0000456", region: "DE"), "+49 40 0000456")
        XCTAssertEqual(PhoneNumberFormat.display("+49691234567", region: "DE"), "+49 69 1234567")
        XCTAssertEqual(PhoneNumberFormat.display("0049891234567", region: "DE"), "+49 89 1234567")
        // Unknown area-code length: country code, then the national digits in one block.
        XCTAssertEqual(PhoneNumberFormat.display("+492304123456", region: "DE"), "+49 2304123456")
        XCTAssertEqual(PhoneNumberFormat.display("+49 221 1234567", region: "DE"), "+49 2211234567")
    }

    func testOtherCountriesUnchanged() {
        XCTAssertEqual(PhoneNumberFormat.display("+43 1 5321234", region: "DE"), "+43 153 21234")
        XCTAssertEqual(PhoneNumberFormat.display("+41441234567", region: "DE"), "+41 441 234567")
        XCTAssertEqual(PhoneNumberFormat.display("+442071234567", region: "DE"), "+44 207 1234567")
        XCTAssertEqual(PhoneNumberFormat.display("+4791234567", region: "DE"), "+47 912 34567")
    }

    func testOtherRegionsUntouched() {
        XCTAssertEqual(PhoneNumberFormat.display("01701234567", region: "US"), "01701234567")
    }

    func testInternationalAndNANP() {
        XCTAssertEqual(PhoneNumberFormat.display("+491701234567", region: "DE"), "+49 170 1234567")
        XCTAssertEqual(PhoneNumberFormat.display("+12025550123", region: "US"), "+1 (202) 555-0123")
    }

    func testServiceCodesAndShortNumbersAsIs() {
        XCTAssertEqual(PhoneNumberFormat.display("**21*0301234567#", region: "DE"), "**21*0301234567#")
        XCTAssertEqual(PhoneNumberFormat.display("112", region: "DE"), "112")
    }

    func testMatchKeyAgreesAcrossNotations() {
        XCTAssertEqual(PhoneNumberFormat.matchKey("+49 170 1234567"), PhoneNumberFormat.matchKey("0170 1234567"))
    }
}
