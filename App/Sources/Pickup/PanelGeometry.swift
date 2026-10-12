import AppKit

/// Pure size/anchor math for the call panels. The panels are sized from the content's reported size
/// (never by `NSHostingView` itself), so a resize cannot feed back into another layout pass.
enum PanelGeometry {
    /// Differences below this (points) are ignored, so identical sizes never touch the window.
    static let epsilon: CGFloat = 0.5

    static func needsResize(from old: CGSize, to new: CGSize) -> Bool {
        abs(old.width - new.width) > epsilon || abs(old.height - new.height) > epsilon
    }

    /// New frame of the given size that keeps the current frame's top-right corner.
    static func anchoredFrame(current: NSRect, newSize: CGSize) -> NSRect {
        NSRect(x: current.maxX - newSize.width, y: current.maxY - newSize.height,
               width: newSize.width, height: newSize.height)
    }

    /// Frame of the given size in the top-right corner of `visibleFrame`, `margin` from the right edge
    /// and `topInset` below the top edge.
    static func cornerFrame(size: CGSize, in visibleFrame: NSRect, margin: CGFloat = 12, topInset: CGFloat = 12) -> NSRect {
        NSRect(x: visibleFrame.maxX - size.width - margin, y: visibleFrame.maxY - topInset - size.height,
               width: size.width, height: size.height)
    }
}
