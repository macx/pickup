import Foundation
import os

/// Groups log lines for grepping. Matches the categories of the phase 0 spike logs.
public enum LogCategory: String, Sendable {
    /// Raw AT lines: `>>` sent by the Mac (HF), `<<` sent by the phone (AG).
    case at = "AT"
    /// Callbacks of the Bluetooth stack.
    case delegate = "DELEGATE"
    /// Link and call state transitions.
    case state = "STATE"
    /// Commands issued by the user or the engine.
    case command = "CMD"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Destination for diagnostic lines. Implementations must be thread-safe.
public protocol DiagnosticLogging: AnyObject, Sendable {
    func log(_ category: LogCategory, _ message: String)
}

/// Discards everything.
public final class NullDiagnosticLog: DiagnosticLogging {
    public init() {}
    public func log(_ category: LogCategory, _ message: String) {}
}

/// Timestamped diagnostic log: a file in `~/Library/Logs/Pickup/` plus the unified log
/// (subsystem `dev.eiken.pickup`). Both are persistent, so phone numbers are always abbreviated
/// with `PhoneNumberRedaction` before anything is written.
public final class DiagnosticLog: DiagnosticLogging, @unchecked Sendable {
    public let fileURL: URL?
    private let fileHandle: FileHandle?
    private let logger: Logger
    private let echoToStandardOutput: Bool
    private let unifiedLogSink: (@Sendable (LogCategory, String) -> Void)?
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        // Local time with milliseconds, so lines can be matched against PacketLogger timestamps.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    /// `~/Library/Logs/Pickup` (inside the container when sandboxed).
    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/Pickup", isDirectory: true)
    }

    /// - Parameters:
    ///   - directory: where to create the log file; nil = unified log only.
    ///   - prefix: file name prefix; the file is `<prefix>-<yyyyMMdd-HHmmss>.log`.
    ///   - keepDays: files with this prefix older than this are deleted at start.
    ///   - echoToStandardOutput: also print each (redacted) line, for runs from Terminal.
    ///   - unifiedLogSink: test seam. Receives exactly the redacted message handed to the unified
    ///     log, so tests can assert that no personal data reaches it. nil in production.
    public init(
        directory: URL? = DiagnosticLog.defaultDirectory,
        prefix: String = "pickup",
        keepDays: Int = 14,
        subsystem: String = "dev.eiken.pickup",
        echoToStandardOutput: Bool = false,
        unifiedLogSink: (@Sendable (LogCategory, String) -> Void)? = nil
    ) {
        self.unifiedLogSink = unifiedLogSink
        self.logger = Logger(subsystem: subsystem, category: "diagnostics")
        self.echoToStandardOutput = echoToStandardOutput
        guard let directory else {
            fileURL = nil
            fileHandle = nil
            return
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.prune(directory: directory, prefix: prefix, keepDays: keepDays)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            stamp.locale = Locale(identifier: "en_US_POSIX")
            let url = directory.appendingPathComponent("\(prefix)-\(stamp.string(from: Date())).log")
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileURL = url
            fileHandle = handle
        } catch {
            logger.error("cannot open log file in \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            fileURL = nil
            fileHandle = nil
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    public func log(_ category: LogCategory, _ message: String) {
        let redacted = PhoneNumberRedaction.redact(message)
        let tag = category.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        unifiedLogSink?(category, redacted)
        switch category {
        case .error: logger.error("[\(tag, privacy: .public)] \(redacted, privacy: .public)")
        case .warning: logger.warning("[\(tag, privacy: .public)] \(redacted, privacy: .public)")
        default: logger.info("[\(tag, privacy: .public)] \(redacted, privacy: .public)")
        }

        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(tag)] \(redacted)\n"
        // The throwing API: a full disk or a closed pipe must not crash the app.
        try? fileHandle?.write(contentsOf: Data(line.utf8))
        if echoToStandardOutput {
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }
    }

    private static func prune(directory: URL, prefix: String, keepDays: Int) {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix + "-") && file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
