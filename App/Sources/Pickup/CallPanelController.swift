import AppKit
import Observation
import SwiftUI

/// Non-activating panel that floats above everything, like Continuity call banners.
final class CallPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true               // must precede `level`: it resets the level
        level = .statusBar                   // above normal windows and the Dock
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Never take keyboard focus unprompted: Return/Esc typed in another app must not answer or
        // end a call. The panel only becomes key when the user clicks it.
        becomesKeyOnlyIfNeeded = true
    }

    /// Natural size of the content (the hosting controller measures it; the panel is sized from this).
    var measure: (() -> CGSize)?
    /// Top-right corner the panel was last positioned at (fallback when the frame has collapsed).
    var anchorCorner = NSPoint.zero

    /// Called when the panel gains (`true`) or loses (`false`) keyboard focus.
    var onKeyChange: ((Bool) -> Void)?

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }

    // Can become key (on click) without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows/hides the banner and the call HUD as `CallUIModel` changes.
@MainActor
final class CallPanelController {
    private let model: CallUIModel
    private var banner: CallPanel?
    private var hud: CallPanel?

    /// Frames of the panels that are currently on screen (used by the call-cycle self test).
    var debugVisibleFrames: [NSRect] { [banner, hud].compactMap { $0 }.filter(\.isVisible).map(\.frame) }

    init(model: CallUIModel) {
        self.model = model
        track()
    }

    /// The call panel on screen: the incoming-call banner, else the call HUD.
    private var visibleCallPanel: CallPanel? {
        [banner, hud].compactMap { $0 }.first { $0.isVisible && $0.alphaValue > 0 }
    }

    var isCallPanelVisible: Bool { visibleCallPanel != nil }

    /// Brings the visible call panel to the front and gives it keyboard focus, on an explicit user action
    /// (click on the menu bar icon or the global shortcut). It still does not activate the app.
    func focusCallPanel() {
        guard let panel = visibleCallPanel else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func track() {
        withObservationTracking {
            _ = (model.incoming != nil, model.active != nil)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.track()
            }
        }
        sync()
    }

    private func sync() {
        banner = update(banner, visible: model.incoming != nil, topInset: 12) {
            IncomingCallRoot(model: model)
        }
        banner?.onKeyChange = { [weak model] in model?.bannerHasFocus = $0 }
        hud = update(hud, visible: model.active != nil, topInset: 12) {
            CallHUDRoot(model: model)
        }
        hud?.onKeyChange = { [weak model] in model?.hudHasFocus = $0 }
        if model.focusHUDWhenShown, model.active != nil {
            model.focusHUDWhenShown = false
            // After the popover (or the link confirmation) has closed and the previous app is active again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.focusCallPanel() }
        }
    }

    private func update<Content: View>(_ panel: CallPanel?, visible: Bool, topInset: CGFloat,
                                       @ViewBuilder content: () -> Content) -> CallPanel? {
        if visible {
            if let panel, panel.isVisible { return panel }
            let panel = panel ?? makePanel(content())
            position(panel, topInset: topInset)
            present(panel)
            return panel
        } else {
            if let panel, panel.isVisible { dismiss(panel) }
            return panel
        }
    }

    private func makePanel<Content: View>(_ content: Content) -> CallPanel {
        let panel = CallPanel()
        // The panel is sized here, from the size the content reports. A hosting view that sizes its own
        // window (`updateAnimatedWindowSize` -> `setFrame(display: true)`) re-enters layout and recursed
        // until the stack overflowed (crashes of 2026-10-11 and 2026-10-12), so its sizing is disabled.
        let sized = content.onGeometryChange(for: CGSize.self, of: \.size, action: { [weak self, weak panel] size in
            guard let self, let panel else { return }
            Task { @MainActor in self.contentSizeChanged(size, panel: panel) }
        })
        let host = NSHostingController(rootView: sized)
        host.sizingOptions = []
        panel.contentViewController = host
        panel.measure = { host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)) }
        return panel
    }

    /// Content reported a new size: resize the visible panel, top-right corner fixed. Programmatic frame
    /// changes use `display: false`, so no layout pass is forced from inside a layout pass.
    private func contentSizeChanged(_ size: CGSize, panel: CallPanel) {
        guard panel.isVisible, size.width > 1, size.height > 1,
              PanelGeometry.needsResize(from: panel.frame.size, to: size) else { return }
        // Anchor to the panel's current top-right corner; a collapsed (zero-size) panel, e.g. while its
        // content is empty during fade-out, falls back to the corner it was positioned at.
        let current = panel.frame.width > 1 ? panel.frame
            : NSRect(x: panel.anchorCorner.x, y: panel.anchorCorner.y, width: 0, height: 0)
        panel.setFrame(PanelGeometry.anchoredFrame(current: current, newSize: size), display: false)
    }

    private func position(_ panel: CallPanel, topInset: CGFloat) {
        let size = panel.measure?() ?? .zero
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Banner and HUD share the top-right corner; they are never shown together.
        let frame = PanelGeometry.cornerFrame(size: size, in: screen.visibleFrame, topInset: topInset)
        panel.anchorCorner = NSPoint(x: frame.maxX, y: frame.maxY)
        panel.setFrame(frame, display: false)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func present(_ panel: CallPanel) {
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()      // never activates the app or steals focus
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss(_ panel: CallPanel) {
        guard !reduceMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            // A new call may have re-presented the panel meanwhile.
            if panel?.alphaValue == 0 { panel?.orderOut(nil) }
        })
    }
}

private struct IncomingCallRoot: View {
    let model: CallUIModel
    var body: some View {
        if let info = model.incoming {
            IncomingCallBannerView(info: info, actions: model.actions, hasFocus: model.bannerHasFocus)
        }
    }
}

private struct CallHUDRoot: View {
    let model: CallUIModel
    var body: some View {
        if let info = model.active {
            CallHUDView(info: info, actions: model.actions, hasFocus: model.hudHasFocus)
        }
    }
}
