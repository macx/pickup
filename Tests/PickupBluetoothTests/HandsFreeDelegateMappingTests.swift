import XCTest
import PickupCore
@testable import PickupBluetooth

/// Pure mapping tests; nothing here touches the Bluetooth hardware (and so no TCC prompt).
final class HandsFreeDelegateMappingTests: XCTestCase {
    func testCurrentCallDictionaryFromPixel() {
        // Phase 0 delegate output: direction=1 index=1 mode=0 mulitiparty=0 number=... status=4 type=145
        let dictionary: [AnyHashable: Any] = [
            "direction": NSNumber(value: 1), "index": NSNumber(value: 1), "mode": NSNumber(value: 0),
            "mulitiparty": NSNumber(value: 0), "number": "+49*******515", "status": NSNumber(value: 4),
            "type": NSNumber(value: 145),
        ]
        XCTAssertEqual(
            HandsFreeDelegate.call(from: dictionary),
            HFPCall(index: 1, direction: .incoming, status: .incoming, number: "+49*******515", numberType: 145)
        )
    }

    func testCorrectlySpelledMultipartyKeyAndMissingNumber() {
        let dictionary: [AnyHashable: Any] = [
            "direction": NSNumber(value: 0), "index": NSNumber(value: 2), "status": NSNumber(value: 0),
            "multiparty": NSNumber(value: 1),
        ]
        XCTAssertEqual(
            HandsFreeDelegate.call(from: dictionary),
            HFPCall(index: 2, direction: .outgoing, status: .active, isMultiparty: true)
        )
    }

    func testIncompleteDictionaryIsIgnored() {
        XCTAssertNil(HandsFreeDelegate.call(from: ["index": NSNumber(value: 1)]))
        XCTAssertNil(HandsFreeDelegate.call(from: ["index": NSNumber(value: 1), "status": NSNumber(value: 9)]))
    }

    func testAddressNormalisation() {
        XCTAssertEqual(AppleHFPTransport.normalizedAddress("AA:BB:CC:DD:EE:FF"), "aa-bb-cc-dd-ee-ff")
    }

    func testResultCodeNameHidesContent() {
        XCTAssertEqual(HandsFreeDelegate.resultCodeName("+BSIR: 1"), "+BSIR")
        XCTAssertEqual(HandsFreeDelegate.resultCodeName(#"+CLIP: "+4930000123",145,,,"Jane Doe""#), "+CLIP")
        XCTAssertEqual(HandsFreeDelegate.resultCodeName("Meet me at 5: PIN 1234"), "<22 chars>")
        XCTAssertEqual(HandsFreeDelegate.resultCodeName("RING"), "RING")
    }
}
