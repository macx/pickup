import CoreGraphics

/// Width of the menu bar popover, which the user can drag between `minimum` and `maximum`. Saved in
/// the user defaults, so it survives relaunches and restarts.
enum PopoverWidth {
    static let minimum: CGFloat = 300
    static let maximum: CGFloat = 2 * minimum
    static let defaultsKey = "popoverWidth"
    /// Step of the VoiceOver adjust actions (increment / decrement).
    static let accessibilityStep: CGFloat = 50

    static func clamped(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return minimum }
        return min(max(width.rounded(), minimum), maximum)
    }

    /// The popover stays centred under its icon, so dragging one edge by `delta` moves both edges:
    /// the width changes by twice the distance and the dragged edge stays under the pointer.
    /// `delta` is positive towards the outside of the dragged edge.
    static func resized(from start: CGFloat, outwardDelta delta: CGFloat) -> CGFloat {
        clamped(start + 2 * delta)
    }
}
