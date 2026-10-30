import ApplicationServices
import AppKit
import XCTest

/// Thin wrapper around `AXUIElement`. XCUIAutomation cannot be used from a SwiftPM test bundle
/// ("Device is not configured for UI testing"), so the tests drive Pickup.app through the macOS
/// Accessibility API (AXIdentifier lookup, AXPress, CGEvent key presses). Needs the Accessibility
/// permission for the process that runs `swift test` (Terminal, iTerm, Claude Code ...).
struct AXElement {
    let ref: AXUIElement

    // MARK: Attributes

    func value(_ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &result) == .success else { return nil }
        return result
    }

    var identifier: String { value("AXIdentifier") as? String ?? "" }
    var role: String { value(kAXRoleAttribute) as? String ?? "" }
    var subrole: String { value(kAXSubroleAttribute) as? String ?? "" }
    var title: String { value(kAXTitleAttribute) as? String ?? "" }
    var label: String { value(kAXDescriptionAttribute) as? String ?? "" }
    var help: String { value(kAXHelpAttribute) as? String ?? "" }
    var stringValue: String {
        if let string = value(kAXValueAttribute) as? String { return string }
        if let number = value(kAXValueAttribute) as? NSNumber { return number.stringValue }
        return ""
    }
    var isEnabled: Bool { (value(kAXEnabledAttribute) as? Bool) ?? true }
    var isFocused: Bool { (value(kAXFocusedAttribute) as? Bool) ?? false }
    var isSelected: Bool { (value(kAXSelectedAttribute) as? Bool) ?? false }

    /// Every piece of text the element exposes to VoiceOver.
    var allText: String { [label, title, stringValue].filter { !$0.isEmpty }.joined(separator: " | ") }

    var frame: CGRect? {
        guard let positionValue = value(kAXPositionAttribute), let sizeValue = value(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    var children: [AXElement] {
        var names = [kAXChildrenAttribute, kAXWindowsAttribute, "AXExtrasMenuBar"]
        if role == "AXMenu" || role == "AXMenuBar" { names = [kAXChildrenAttribute] }
        var seen: [AXElement] = []
        for name in names {
            guard let raw = value(name) else { continue }
            var found: [AXElement] = []
            if let array = raw as? [AXUIElement] {
                found = array.map(AXElement.init)
            } else if CFGetTypeID(raw) == AXUIElementGetTypeID() {
                found = [AXElement(ref: raw as! AXUIElement)]
            }
            // The application's main menu bar (Apple menu, recents ...) is huge and never relevant.
            if name != "AXExtrasMenuBar" { found.removeAll { $0.role == "AXMenuBar" } }
            seen += found
        }
        return seen
    }

    // MARK: Search

    /// Breadth-first search below this element.
    func find(_ id: String, maxNodes: Int = 4000) -> AXElement? {
        first(maxNodes: maxNodes) { $0.identifier == id }
    }

    func first(maxNodes: Int = 4000, where predicate: (AXElement) -> Bool) -> AXElement? {
        var queue = [self]
        var index = 0
        while index < queue.count, index < maxNodes {
            let node = queue[index]
            index += 1
            if predicate(node) { return node }
            queue += node.children
        }
        return nil
    }

    func all(maxNodes: Int = 4000, where predicate: (AXElement) -> Bool) -> [AXElement] {
        var queue = [self]
        var index = 0
        var result: [AXElement] = []
        while index < queue.count, index < maxNodes {
            let node = queue[index]
            index += 1
            if predicate(node) { result.append(node) }
            queue += node.children
        }
        return result
    }

    // MARK: Actions

    @discardableResult
    func press() -> Bool { AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success }

    func perform(_ action: String) -> Bool { AXUIElementPerformAction(ref, action as CFString) == .success }

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func focus() { AXUIElementSetAttributeValue(ref, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
}

// MARK: - Keyboard

enum Key {
    static let returnKey: CGKeyCode = 36
    static let escape: CGKeyCode = 53
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let tab: CGKeyCode = 48
    static let space: CGKeyCode = 49
    static let comma: CGKeyCode = 43
    static let q: CGKeyCode = 12
    static let w: CGKeyCode = 13
    static let c: CGKeyCode = 8
}

/// Keyboard events posted straight to the process (they do not go to whatever app is in front).
struct Keyboard {
    let pid: pid_t

    func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    /// Types text as unicode key events, independent of the keyboard layout.
    func type(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.postToPid(pid)
            }
        }
    }
}

// MARK: - Polling

@MainActor
enum Wait {
    /// Polls `condition` until it holds or `timeout` expires. The run loop keeps spinning between polls.
    @discardableResult
    static func until(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while Date() < deadline
        return condition()
    }
}

extension AXElement {
    /// Debug helper: indented tree with role, identifier and text.
    func dump(depth: Int = 0, maxDepth: Int = 12) -> String {
        var line = String(repeating: "  ", count: depth) + "\(role)\(subrole.isEmpty ? "" : "/\(subrole)") id='\(identifier)' text='\(allText)'"
        if let f = frame { line += " \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }
        var out = line + "\n"
        guard depth < maxDepth else { return out }
        for child in children { out += child.dump(depth: depth + 1, maxDepth: maxDepth) }
        return out
    }
}
