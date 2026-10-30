import Foundation

/// Static facts about the app shown in the About panel.
enum AppInfo {
    /// Public source repository, linked in the About panel. `nil` hides the link.
    static let repositoryURL: String? = "https://github.com/macx/pickup"
    /// The author's website, linked in the About panel. `nil` hides the link.
    static let websiteURL: String? = "https://davideiken.de"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
