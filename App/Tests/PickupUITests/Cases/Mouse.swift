import CoreGraphics
import Foundation

/// Real mouse events (HID tap): used only where no accessibility action exists (the long press on 0).
/// The cursor is moved briefly and put back.
@MainActor
enum Mouse {
    static func longPress(at point: CGPoint, duration: TimeInterval) {
        let saved = CGEvent(source: nil)?.location ?? point
        func post(_ type: CGEventType) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved)
        Wait.until(0.1) { false }
        post(.leftMouseDown)
        Wait.until(duration) { false }
        post(.leftMouseUp)
        Wait.until(0.1) { false }
        CGWarpMouseCursorPosition(saved)
    }
}
