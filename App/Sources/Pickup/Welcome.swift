import Foundation
import Security

/// When the welcome window appears: at the first launch, and, while Pickup is not signed with a
/// Developer ID, after every update. An ad-hoc signature changes with each build, so macOS may ask for
/// the permissions again; the window explains why and offers them in one place.
enum WelcomePolicy {
    enum Reason: Equatable {
        case firstLaunch
        /// A new version without a Developer ID signature: permissions may have been reset.
        case updatedUnsigned
    }

    static let shownForVersionKey = "welcomeShownForVersion"

    /// `shownFor`: the version the window was last shown for (nil = never). Rebuilds of the same
    /// version (development) do not show it again.
    static func reason(shownFor: String?, currentVersion: String, developerIDSigned: Bool) -> Reason? {
        guard let shownFor else { return .firstLaunch }
        guard !developerIDSigned, shownFor != currentVersion else { return nil }
        return .updatedUnsigned
    }

    /// "0.3.0 (42)": version and build, so every release counts as an update.
    static var currentVersion: String { "\(AppInfo.version) (\(AppInfo.build))" }

    /// True if the running app carries a team identifier (Developer ID or App Store), false for
    /// ad-hoc signed or unsigned builds.
    static var isDeveloperIDSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        return dictionary[kSecCodeInfoTeamIdentifier as String] is String
    }

    /// Reason to show the window at this launch, from the saved state. Never in tests.
    static func launchReason(defaults: UserDefaults = .standard) -> Reason? {
        guard !TestMode.isActive else { return nil }
        if UserDefaults.standard.bool(forKey: "PickupOpenWelcome") { return .firstLaunch }   // visual checks
        return reason(shownFor: defaults.string(forKey: shownForVersionKey), currentVersion: currentVersion,
                      developerIDSigned: isDeveloperIDSigned)
    }

    static func markShown(defaults: UserDefaults = .standard) {
        guard !TestMode.isActive else { return }
        defaults.set(currentVersion, forKey: shownForVersionKey)
    }
}
