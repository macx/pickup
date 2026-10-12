import XCTest
@testable import Pickup

final class ContactSearchTests: XCTestCase {
    private let entries: [ContactEntry] = [
        ContactEntry(id: "1", name: "Günter Hansen", organization: "IT-P GmbH", phones: [
            .init(label: "mobile", number: "+49 170 9125550"), .init(label: "work", number: "+49 30 555123")]),
        ContactEntry(id: "2", name: "Anna Schmidt", phones: [.init(label: nil, number: "0170 1234567")]),
        ContactEntry(id: "3", name: "Hanna Köhler", organization: "Hansen & Söhne", phones: [.init(label: "home", number: "089 123456")]),
        ContactEntry(id: "4", name: "No Number", phones: []),
    ]

    private func names(_ query: String) -> [String] { ContactSearch.search(query, in: entries).map(\.name) }

    func testDiacriticAndCaseInsensitive() {
        XCTAssertEqual(names("gunter").first, "Günter Hansen")
        XCTAssertEqual(names("KOHLER"), ["Hanna Köhler"])
        XCTAssertEqual(names("günt").first, "Günter Hansen")
    }

    func testWordPrefixNotSubstring() {
        XCTAssertTrue(names("ans").isEmpty)           // "Hansen" contains "ans", but no word starts with it
        XCTAssertFalse(names("han").isEmpty)
    }

    func testAllWordsMustMatchInAnyOrder() {
        XCTAssertEqual(names("hansen gün"), ["Günter Hansen", "Günter Hansen"])
        XCTAssertEqual(names("schmidt anna"), ["Anna Schmidt"])
    }

    func testOrganisationIsSearchable() {
        XCTAssertEqual(names("gmbh"), ["Günter Hansen", "Günter Hansen"])
    }

    func testOneRowPerNumber() {
        let result = ContactSearch.search("gunter", in: entries)
        XCTAssertEqual(result.map(\.number), ["+49 170 9125550", "+49 30 555123"])
        XCTAssertEqual(result.map(\.label), ["mobile", "work"])
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }

    func testContactsWithoutNumbersAreSkipped() {
        XCTAssertTrue(names("no number").isEmpty)
    }

    func testOrderingFirstNameWordBeforeOtherWordsBeforeOrganisation() {
        // "han": Hanna (first word) < Günter Hansen (second word) < nothing else; organisation-only comes last.
        XCTAssertEqual(names("han"), ["Hanna Köhler", "Günter Hansen", "Günter Hansen"])
        // "hansen": Günter (name word 2) before Hanna (organisation only)
        XCTAssertEqual(names("hansen"), ["Günter Hansen", "Günter Hansen", "Hanna Köhler"])
    }

    func testDigitSearchMatchesNationalAndInternational() {
        XCTAssertEqual(ContactSearch.search("0170 91", in: entries).map(\.name), ["Günter Hansen"])
        XCTAssertEqual(ContactSearch.search("+49 170 91", in: entries).map(\.name), ["Günter Hansen"])
        XCTAssertEqual(Set(ContactSearch.search("170", in: entries).map(\.name)), ["Günter Hansen", "Anna Schmidt"])
    }

    func testDigitSearchNeedsThreeDigits() {
        XCTAssertTrue(ContactSearch.search("17", in: entries).isEmpty)
    }

    func testEmptyAndPunctuationOnlyQueries() {
        XCTAssertTrue(names("").isEmpty)
        XCTAssertTrue(names("   ").isEmpty)
        XCTAssertTrue(names("-").isEmpty)
    }

    func testNumericQueryDetection() {
        XCTAssertTrue(ContactSearch.isNumericQuery("+49 (170) 12"))
        XCTAssertFalse(ContactSearch.isNumericQuery("anna 12"))
        XCTAssertFalse(ContactSearch.isNumericQuery(""))
    }
}

final class ContactSearchInternationalTests: XCTestCase {
    private let entries: [ContactEntry] = [
        ContactEntry(id: "a", name: "Anna", phones: [.init(label: nil, number: "0170 9125550")]),          // stored nationally
        ContactEntry(id: "b", name: "Berta", phones: [.init(label: nil, number: "+49 30 555123")]),         // stored internationally, short area code
        ContactEntry(id: "c", name: "Søren Łukasz", phones: [.init(label: nil, number: "+45 1234 5678")]),
    ]

    private func names(_ q: String) -> [String] { ContactSearch.search(q, in: entries).map(\.name) }

    func testInternationalQueryMatchesNationalStorage() {
        XCTAssertEqual(names("+49 170 9125"), ["Anna"])
        XCTAssertEqual(names("0049 170 9125"), ["Anna"])
    }

    func testNationalQueryMatchesInternationalStorage() {
        XCTAssertEqual(names("030 5551"), ["Berta"])
        XCTAssertEqual(names("+49 30 555"), ["Berta"])
    }

    func testFoldsStrokedLetters() {
        XCTAssertEqual(names("soren"), ["Søren Łukasz"])
        XCTAssertEqual(names("lukasz"), ["Søren Łukasz"])
    }
}

final class DialerRowsTests: XCTestCase {
    private let contact = ContactSearchResult(id: "x|0", name: "Anna", label: nil, number: "+49 170 123", imageData: nil)

    func testContactRowsAreNeverTrusted() {
        let rows = DialerRows.rows(for: "anna", contacts: [contact], fromKeypad: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].allowServiceCode)
        XCTAssertFalse(rows[0].requiresConfirmation)
    }

    func testLettersSuppressTheCallRow() {
        let rows = DialerRows.rows(for: "0170abc", contacts: [], fromKeypad: false)
        XCTAssertTrue(rows.isEmpty)
    }

    func testPlainNumberOffersCallRowFirst() {
        let rows = DialerRows.rows(for: "+49 170 123", contacts: [contact], fromKeypad: false)
        XCTAssertEqual(rows.count, 2)
        if case .call = rows[0].kind {} else { XCTFail("first row must be the call row") }
        XCTAssertFalse(rows[0].requiresConfirmation)
    }

    func testServiceCodeFromKeypadIsTrusted() {
        let rows = DialerRows.rows(for: "*21*0301234567#", contacts: [], fromKeypad: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].allowServiceCode)
        XCTAssertFalse(rows[0].requiresConfirmation)
    }

    func testTypedOrPastedServiceCodeIsFlaggedNotTrusted() {
        let rows = DialerRows.rows(for: "**21*0301234567#", contacts: [], fromKeypad: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].allowServiceCode)
        XCTAssertTrue(rows[0].requiresConfirmation)
    }

    func testEmptyTextHasNoRows() {
        XCTAssertTrue(DialerRows.rows(for: "", contacts: [], fromKeypad: true).isEmpty)
    }
}

final class KeypadVisibilityTests: XCTestCase {
    func testDialQueries() {
        for text in ["0", "0170", "+49 170 12", "(030) 123-45", "*21*0301#", " 12 "] {
            XCTAssertTrue(KeypadVisibility.isDialQuery(text), text)
        }
    }

    func testNameAndEmptyQueriesAreNotDialQueries() {
        for text in ["", "   ", "anna", "anna 12", "0170abc", "-", "()"] {
            XCTAssertFalse(KeypadVisibility.isDialQuery(text), text)
        }
    }

    func testAutoOpenForNumbersAndFoldAwayForNames() {
        XCTAssertTrue(KeypadVisibility.resolve(text: "017", manuallyOpen: false, autoDismissed: false))
        XCTAssertFalse(KeypadVisibility.resolve(text: "ann", manuallyOpen: false, autoDismissed: false))
        XCTAssertFalse(KeypadVisibility.resolve(text: "", manuallyOpen: false, autoDismissed: false))
    }

    func testManualOpenSurvivesNamesAndClearing() {
        XCTAssertTrue(KeypadVisibility.resolve(text: "ann", manuallyOpen: true, autoDismissed: false))
        XCTAssertTrue(KeypadVisibility.resolve(text: "", manuallyOpen: true, autoDismissed: false))
    }

    func testDismissedAutoKeypadStaysClosedForNumbers() {
        XCTAssertFalse(KeypadVisibility.resolve(text: "0170", manuallyOpen: false, autoDismissed: true))
    }
}

final class KeypadKeyTests: XCTestCase {
    func testOnlyZeroHasLongPressPlus() {
        XCTAssertEqual(KeypadKey.longPressValue(for: "0"), "+")
        for key in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"] {
            XCTAssertNil(KeypadKey.longPressValue(for: key), key)
            XCTAssertNil(KeypadKey.secondaryGlyph(for: key), key)
        }
    }

    func testSecondaryGlyphIsThePlus() {
        XCTAssertEqual(KeypadKey.secondaryGlyph(for: "0"), "+")
    }
}

@MainActor
final class TestHooksTests: XCTestCase {
    func testDemoContactsCoverTheUITestCases() {
        let directory = ContactsDirectory()
        directory.loadDemo()
        let names = Set(directory.entries.map(\.name))
        XCTAssertTrue(names.contains("Jane Doe"))
        XCTAssertTrue(names.contains("John Roe"))
        XCTAssertTrue(names.contains("Øystein Åberg"))
        XCTAssertTrue(directory.entries.contains { $0.name.count > 60 })            // very long name
        XCTAssertTrue(directory.entries.contains { $0.phones.count >= 3 })          // several numbers
        XCTAssertEqual(directory.match(for: "+491700000123")?.name, "Jane Doe")     // caller lookup uses the same data
        XCTAssertEqual(directory.search("oystein").first?.name, "Øystein Åberg")    // diacritic folding
    }

    func testKeypadIdentifiers() {
        XCTAssertEqual(DialerView.identifier(forKey: "0"), "key-0")
        XCTAssertEqual(DialerView.identifier(forKey: "9"), "key-9")
        XCTAssertEqual(DialerView.identifier(forKey: "*"), "key-star")
        XCTAssertEqual(DialerView.identifier(forKey: "#"), "key-hash")
    }
}

final class CallDurationFormatTests: XCTestCase {
    func testVisibleFormat() {
        XCTAssertEqual(CallDurationFormat.string(0), "0:00")
        XCTAssertEqual(CallDurationFormat.string(5.9), "0:05")
        XCTAssertEqual(CallDurationFormat.string(65), "1:05")
        XCTAssertEqual(CallDurationFormat.string(3725), "1:02:05")
        XCTAssertEqual(CallDurationFormat.string(-3), "0:00")
    }

    func testSpokenValueChangesAndIsNotEmpty() {
        let a = CallDurationFormat.spoken(65)
        let b = CallDurationFormat.spoken(66)
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, b)   // a changing value, so VoiceOver reads fresh time on focus
    }
}
