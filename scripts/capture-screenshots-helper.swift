// Helper for scripts/capture-screenshots.sh (compiled to App/.build/screenshots/helper).
//
//   helper windows <pid>              list the on-screen windows of <pid>: id layer x y w h title
//   helper press <pid> <identifier>   AXPress the first element with that accessibility identifier
//   helper front <pid>                make <pid> the active app (key window looks active in the shot)
//   helper advance                    post the test-scenario advance notification (debug builds only)
//
// `press` needs the Accessibility permission for the calling terminal (it never moves the mouse).
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func windows(pid: Int32) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
        let id = info[kCGWindowNumber as String] as? Int ?? 0
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let title = info[kCGWindowName as String] as? String ?? ""
        print(id, layer, Int(bounds["X"] ?? 0), Int(bounds["Y"] ?? 0), Int(bounds["Width"] ?? 0),
              Int(bounds["Height"] ?? 0), title)
    }
}

func find(_ element: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
    if depth > 40 { return nil }
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success,
       (value as? String) == identifier {
        return element
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let array = children as? [AXUIElement] else { return nil }
    for child in array {
        if let hit = find(child, identifier: identifier, depth: depth + 1) { return hit }
    }
    return nil
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: helper windows <pid> | press <pid> <identifier> | advance") }
switch args[1] {
case "windows":
    guard args.count == 3, let pid = Int32(args[2]) else { fail("usage: helper windows <pid>") }
    windows(pid: pid)
case "press":
    guard args.count == 4, let pid = Int32(args[2]) else { fail("usage: helper press <pid> <identifier>") }
    guard AXIsProcessTrusted() else { fail("helper: the terminal needs the Accessibility permission") }
    let app = AXUIElementCreateApplication(pid)
    guard let element = find(app, identifier: args[3]) else { fail("helper: no element '\(args[3])'") }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { fail("helper: AXPress failed (\(result.rawValue))") }
case "front":
    guard args.count == 3, let pid = Int32(args[2]) else { fail("usage: helper front <pid>") }
    guard AXIsProcessTrusted() else { fail("helper: the terminal needs the Accessibility permission") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("helper: could not activate \(pid)") }
case "advance":
    DistributedNotificationCenter.default().postNotificationName(
        .init("dev.eiken.pickup.test.advance"), object: nil, userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
default:
    fail("helper: unknown command \(args[1])")
}
