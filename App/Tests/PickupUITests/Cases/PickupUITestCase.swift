import AppKit
import ApplicationServices
import XCTest

/// Base class: launches the debug Pickup.app with a scripted phone, finds elements by accessibility
/// identifier and always terminates the app again.
@MainActor
class PickupUITestCase: XCTestCase {
    var process: Process?
    var app: AXElement!
    var keyboard: Keyboard!
    var scratch: URL!
    var language = "en"

    static var appBundle: URL {
        let path = ProcessInfo.processInfo.environment["PICKUP_APP"] ?? ""
        return URL(fileURLWithPath: path)
    }

    override func setUp() async throws {
        continueAfterFailure = true   // a failing test must not abort the rest of the run
        guard AXIsProcessTrusted() else {
            XCTFail("Accessibility permission is missing for the process running the tests")
            throw XCTSkip("no Accessibility permission")
        }
        Self.killStrayPickups()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pickup-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        terminateApp()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Process

    static func killStrayPickups() {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.eiken.pickup") { running.forceTerminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.eiken.pickup").isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Launches the scenario and waits until the status item is visible.
    func launch(_ scenario: String, language: String = "en", fastClock: Bool = true, extra: [String] = []) throws {
        self.language = language
        let executable = Self.appBundle.appendingPathComponent("Contents/MacOS/Pickup")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Pickup.app not found at \(executable.path); run scripts/run-ui-tests.sh")
        }
        let process = Process()
        process.executableURL = executable
        var arguments = ["-PickupTestScenario", scenario, "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"]
        if fastClock { arguments += ["-PickupTestFastClock", "YES"] }
        process.arguments = arguments + extra
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("pickup-test-logs"))
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let pid = process.processIdentifier
        app = AXElement(ref: AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(app.ref, 2)   // a modal menu never answers AXPress; do not wait the default 6 s
        keyboard = Keyboard(pid: pid)
        XCTAssertTrue(Wait.until(15) { app.find("status-item") != nil }, "status item did not appear")
    }

    func terminateApp() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        self.process = nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Elements

    func element(_ id: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> AXElement {
        var found: AXElement?
        Wait.until(timeout) { found = app.find(id); return found != nil }
        guard let found else {
            XCTFail("element '\(id)' not found within \(timeout) s", file: file, line: line)
            return AXElement(ref: AXUIElementCreateSystemWide())
        }
        return found
    }

    /// Frame of an element once it stopped moving (popover/panels animate and resize after state changes).
    func stableFrame(_ id: String, timeout: TimeInterval = 6) -> CGRect? {
        var last: CGRect?
        var stableSince: Date?
        var result: CGRect?
        Wait.until(timeout) {
            guard let frame = app.find(id)?.frame else { last = nil; stableSince = nil; return false }
            if frame == last {
                if Date().timeIntervalSince(stableSince ?? Date()) >= 0.4 { result = frame; return true }
            } else { last = frame; stableSince = Date() }
            return false
        }
        return result
    }

    func exists(_ id: String) -> Bool { app.find(id) != nil }

    func waitExists(_ id: String, timeout: TimeInterval = 8) -> Bool { Wait.until(timeout) { exists(id) } }
    func waitGone(_ id: String, timeout: TimeInterval = 8) -> Bool { Wait.until(timeout) { !exists(id) } }

    /// The text of an element once it satisfies `predicate`.
    func waitText(_ id: String, timeout: TimeInterval = 8, _ predicate: (String) -> Bool) -> Bool {
        Wait.until(timeout) { app.find(id).map { predicate($0.allText) } ?? false }
    }

    // MARK: Actions

    /// Presses the status item. Right after launch the press is sometimes ignored (the app is still
    /// finishing its launch), so it is repeated, but only while the popover is still closed.
    func openPopover(file: StaticString = #filePath, line: UInt = #line) {
        let item = element("status-item")
        for _ in 0..<5 {
            if exists("popover-root") { return }
            item.press()
            if Wait.until(1.5, { exists("popover-root") }) { return }
        }
        XCTFail("popover did not open", file: file, line: line)
    }

    func closePopoverIfOpen() {
        if exists("popover-root") { keyboard.press(Key.escape) }
    }

    /// Advances the scripted phone by one step.
    func advance() {
        DistributedNotificationCenter.default().postNotificationName(
            .init("dev.eiken.pickup.test.advance"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    func type(_ text: String) { keyboard.type(text) }

    /// Content of the search field.
    var searchText: String { app.find("search-field")?.stringValue ?? "" }

    /// The test log of the app (`<scratch>/pickup-test-logs/*.log`), redacted by the app.
    var appLog: String {
        // The app writes to FileManager.temporaryDirectory/pickup-test-logs (the per-user temp dir; TMPDIR is ignored).
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pickup-test-logs")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    // MARK: Screenshots (best effort; needs the Screen Recording permission to show other apps' windows)

    static var screenshotDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PICKUP_UI_SCREENSHOTS"] { return URL(fileURLWithPath: path) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("pickup-ui-screenshots")
    }

    func screenshot(_ name: String, of id: String) {
        guard let frame = app.find(id)?.frame, frame.width > 1 else { return }
        try? FileManager.default.createDirectory(at: Self.screenshotDirectory, withIntermediateDirectories: true)
        let file = Self.screenshotDirectory.appendingPathComponent("\(name)-\(language).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))", file.path]
        try? capture.run()
        capture.waitUntilExit()
    }
}

// MARK: - Shared helpers for the test classes

extension PickupUITestCase {
    /// Localised strings the tests compare against (from Localizable.xcstrings).
    func s(_ english: String, _ german: String) -> String { language == "de" ? german : english }

    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    /// Opens the popover, types `text` and waits until the search field shows it.
    func search(_ text: String) {
        openPopover()
        let field = element("search-field")
        Wait.until(3) { field.focus(); return field.isFocused }
        type(text)
        XCTAssertTrue(Wait.until { searchText == text }, "search field shows '\(searchText)', expected '\(text)'")
    }

    /// Dials the first contact match for `query` with the keyboard only (type, Return).
    func dialWithKeyboard(_ query: String) {
        search(query)
        keyboard.press(Key.returnKey)
        XCTAssertTrue(waitExists("call-hud"), "HUD did not appear after Return")
    }

    func hudState() -> String { app.find("hud-state")?.allText ?? "" }
    func hudTimer() -> String { app.find("hud-timer")?.allText ?? "" }

    /// Frames of all listed identifiers must lie inside `container` and must not overlap each other.
    func assertLayout(container: String, children ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard let box = app.find(container)?.frame else { return XCTFail("no frame for \(container)", file: file, line: line) }
        var frames: [(String, CGRect)] = []
        for id in ids {
            guard let frame = app.find(id)?.frame, frame.width > 0 else { XCTFail("no frame for \(id)", file: file, line: line); continue }
            XCTAssertTrue(box.insetBy(dx: -1.5, dy: -1.5).contains(frame), "\(id) \(frame) sticks out of \(container) \(box)", file: file, line: line)
            frames.append((id, frame))
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let overlap = a.1.insetBy(dx: 1, dy: 1).intersection(b.1.insetBy(dx: 1, dy: 1))
                XCTAssertTrue(overlap.isNull || overlap.width <= 0 || overlap.height <= 0, "\(a.0) overlaps \(b.0)", file: file, line: line)
            }
        }
    }

    /// Labels of all controls below `root` must be non-empty (VoiceOver).
    func assertControlsHaveLabels(in root: AXElement, file: StaticString = #filePath, line: UInt = #line) {
        let controls = root.all { ["AXButton", "AXCheckBox", "AXTextField", "AXPopUpButton", "AXRadioButton", "AXSlider"].contains($0.role) }
        XCTAssertFalse(controls.isEmpty, "no controls found", file: file, line: line)
        for control in controls where !["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(control.subrole) {
            XCTAssertFalse(control.allText.trimmingCharacters(in: .whitespaces).isEmpty,
                           "control \(control.role) id='\(control.identifier)' has no accessible label", file: file, line: line)
        }
    }
}
