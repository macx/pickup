import AppKit
import Observation

/// Whether Pickup is the default app for `tel:` / `callto:` links, and a way to make it so.
///
/// Registration is not the problem: `CFBundleURLTypes` in Info.plist makes Pickup a candidate,
/// but the system keeps whichever app the user (or an installer) chose before, e.g. Apple's
/// Phone/FaceTime app. `NSWorkspace.setDefaultApplication` changes that.
@MainActor
@Observable
final class LinkHandlerStatus {
    static let schemes = ["tel", "callto"]
    private static let hintDismissedKey = "phoneLinkHintDismissed"

    private(set) var isDefault = false
    /// Display name of the app that currently opens `tel:` links.
    private(set) var handlerName: String?
    /// Localized reason the last attempt to become the default failed.
    private(set) var failure: String?
    /// True after an attempt that did not result in Pickup being the default.
    private(set) var lastErrorDetail: String?
    private(set) var needsManualStep = false
    private(set) var hintDismissed = UserDefaults.standard.bool(forKey: LinkHandlerStatus.hintDismissedKey)

    var shouldShowHint: Bool { !isDefault && !hintDismissed }

    func dismissHint() {
        hintDismissed = true
        UserDefaults.standard.set(true, forKey: Self.hintDismissedKey)
    }

    func refresh() {
        // Compare by bundle identifier: the system records the default per app, not per copy on disk.
        let ours = Bundle.main.bundleIdentifier
        let handlers = Self.schemes.map { scheme in
            URL(string: "\(scheme):+10000000000").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        }
        isDefault = handlers.allSatisfy { $0.flatMap { Bundle(url: $0)?.bundleIdentifier } == ours }
        if let tel = handlers.first.flatMap({ $0 }) {
            handlerName = FileManager.default.displayName(atPath: tel.path)
                .replacingOccurrences(of: ".app", with: "")
        } else {
            handlerName = nil
        }
        if isDefault { failure = nil; needsManualStep = false }
    }

    /// Sets Pickup as the handler for every scheme, then re-reads the real state; never assumes success.
    func makeDefault() async {
        guard !TestMode.isActive else { return }   // tests never change the system's default app
        failure = nil
        var firstError: Error?
        for scheme in Self.schemes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                                   toOpenURLsWithScheme: scheme)
            } catch {
                firstError = firstError ?? error
                let ns = error as NSError
                lastErrorDetail = "\(ns.domain) \(ns.code)"
            }
        }
        refresh()
        guard !isDefault else { return }
        needsManualStep = true
        if let firstError {
            failure = String(localized: "macOS refused the change: \(firstError.localizedDescription)",
                             comment: "Error under the phone-link setting. %@ is the system's own error text.")
        } else {
            failure = String(localized: "macOS did not apply the change.",
                             comment: "Error under the phone-link setting when the system reported success but Pickup is still not the default.")
        }
    }
}
