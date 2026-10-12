import AppKit
import SwiftUI

/// The popover's "more" menu as a native `NSMenu`, so the round glass button can be an ordinary
/// `Button` (SwiftUI's `Menu` ignores the label size under the glass style). The menu is anchored
/// below the button view, so it works for mouse, keyboard and VoiceOver activation alike.
@MainActor
final class AppMenu: NSObject {
    private static var current: AppMenu?
    private let openSettings: () -> Void
    private let showAbout: () -> Void

    private init(openSettings: @escaping () -> Void, showAbout: @escaping () -> Void) {
        self.openSettings = openSettings
        self.showAbout = showAbout
    }

    static func pop(from anchor: NSView?, openSettings: @escaping () -> Void, showAbout: @escaping () -> Void) {
        let helper = AppMenu(openSettings: openSettings, showAbout: showAbout)
        current = helper   // keep the targets alive while the menu is open
        let menu = NSMenu()
        menu.addItem(helper.item(String(localized: "Settings…"), #selector(settings), key: ",", id: "menu-settings"))
        menu.addItem(helper.item(String(localized: "About Pickup"), #selector(about), key: "", id: "menu-about"))
        menu.addItem(.separator())
        menu.addItem(helper.item(String(localized: "Quit Pickup"), #selector(quit), key: "q", id: "menu-quit"))
        guard let anchor else { return }
        // Just below the button's bottom edge, left-aligned.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : -4), in: anchor)
    }

    private func item(_ title: String, _ action: Selector, key: String, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.identifier = NSUserInterfaceItemIdentifier(id)   // for UI tests
        item.target = self
        return item
    }

    @objc private func settings() { openSettings() }
    @objc private func about() { showAbout() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// Captures the AppKit view behind a SwiftUI control, to anchor an `NSMenu` to it.
struct AnchorView: NSViewRepresentable {
    final class Holder { weak var view: NSView? }
    let holder: Holder
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}
