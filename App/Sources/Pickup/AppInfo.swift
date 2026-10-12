import Foundation

/// Static facts about the app shown in the About panel.
enum AppInfo {
    /// Public source repository. `nil` (or a placeholder) hides the link in the About panel.
    /// Set it once the public `pickup` repository exists.
    static let repositoryURL: String? = nil

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
