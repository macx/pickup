import Foundation

/// Switches for UI/scenario testing (`-PickupTestScenario <name>`, see docs/TESTING.md).
///
/// The scripted phone and its control channel are compiled only when `PICKUP_TESTING` is defined, which
/// `App/Package.swift` does for debug builds only. In release builds `isActive` is a constant `false`,
/// so every `if TestMode.isActive` branch in the app is dead code and nothing can enable it.
enum TestMode {
    #if PICKUP_TESTING
    static let scenarioName: String? = UserDefaults.standard.string(forKey: "PickupTestScenario")
    static var isActive: Bool { scenarioName != nil }
    #else
    static let scenarioName: String? = nil
    static var isActive: Bool { false }
    #endif

    /// Invented contacts and no real address-book access: any test scenario or `-PickupDemo` launch.
    static var usesInventedContacts: Bool {
        isActive || UserDefaults.standard.string(forKey: "PickupDemo") != nil
    }
}
