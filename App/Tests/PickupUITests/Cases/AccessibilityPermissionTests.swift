import ApplicationServices
import XCTest

/// Runs first (scripts/run-ui-tests.sh) and launches nothing: only checks that this process may use
/// the Accessibility API.
final class AccessibilityPermissionTests: XCTestCase {
    func testAccessibilityPermissionIsGranted() {
        XCTAssertTrue(AXIsProcessTrusted(), "ACCESSIBILITY_NOT_GRANTED")
    }
}
