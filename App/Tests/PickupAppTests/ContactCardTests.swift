import XCTest
@testable import Pickup

/// The vCard for "Add to Contacts…": data from the phone must never add lines or properties.
final class ContactCardTests: XCTestCase {
    func testCardCarriesNameAndNumber() {
        let card = ContactCard.vCard(name: "Jane Doe", number: "+49 30 0000123")
        XCTAssertEqual(card, "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Doe;Jane;;;\r\nFN:Jane Doe\r\nTEL;TYPE=VOICE:+49 30 0000123\r\nEND:VCARD\r\n")
        XCTAssertTrue(ContactCard.vCard(name: nil, number: "+49300000123").contains("\r\nN:;;;;\r\nFN:\r\n"))
    }

    func testPhoneDataCannotInjectProperties() {
        let card = ContactCard.vCard(name: "Jane\r\nEMAIL:x@example.com;Doe", number: "123\nEND:VCARD")
        let lines = card.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 6, card)
        XCTAssertFalse(lines.contains { $0.hasPrefix("EMAIL") })
        XCTAssertEqual(lines.filter { $0 == "END:VCARD" }.count, 1)
        XCTAssertEqual(ContactCard.escape("a,b;c\\d\u{07}"), #"a\,b\;c\\d"#)
    }

    func testFileNameIsSafe() {
        XCTAssertEqual(ContactCard.fileName(name: "Jane Doe", number: "1"), "Jane Doe.vcf")
        XCTAssertEqual(ContactCard.fileName(name: "../x/y", number: "1"), "..xy.vcf")
        XCTAssertEqual(ContactCard.fileName(name: nil, number: "+49 30 0000123"), "+49 30 0000123.vcf")
        XCTAssertEqual(ContactCard.fileName(name: "", number: ""), "Contact.vcf")
    }
}
