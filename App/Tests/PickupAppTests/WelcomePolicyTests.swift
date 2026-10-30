import XCTest
@testable import Pickup

final class WelcomePolicyTests: XCTestCase {
    func testFirstLaunchAlwaysShowsTheWelcome() {
        XCTAssertEqual(WelcomePolicy.reason(shownFor: nil, currentVersion: "0.3.0 (42)", developerIDSigned: false), .firstLaunch)
        XCTAssertEqual(WelcomePolicy.reason(shownFor: nil, currentVersion: "1.0.0 (60)", developerIDSigned: true), .firstLaunch)
    }

    func testUnsignedUpdatesShowItAgainBecausePermissionsMayBeReset() {
        XCTAssertEqual(WelcomePolicy.reason(shownFor: "0.3.0 (42)", currentVersion: "0.4.0 (47)", developerIDSigned: false), .updatedUnsigned)
        XCTAssertNil(WelcomePolicy.reason(shownFor: "0.3.0 (42)", currentVersion: "0.3.0 (42)", developerIDSigned: false),
                     "rebuilds of the same version (development) stay quiet")
    }

    func testSignedUpdatesKeepTheirPermissionsAndStayQuiet() {
        XCTAssertNil(WelcomePolicy.reason(shownFor: "1.0.0 (60)", currentVersion: "1.1.0 (65)", developerIDSigned: true))
    }
}
