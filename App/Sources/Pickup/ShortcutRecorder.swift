import AppKit
import SwiftUI

/// Click to record a shortcut, Esc cancels, the x (or Delete while recording) clears it.
/// Requires at least one of ⌘ ⌃ ⌥ so plain keys can never be taken over.
struct ShortcutRecorder: View {
    private let manager = GlobalShortcutManager.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(verbatim: label)
                    .monospacedDigit()
                    .frame(minWidth: 96)
            }
            .accessibilityIdentifier("settings-shortcut-recorder")
            .accessibilityLabel(Text("Global shortcut"))
            .accessibilityValue(Text(verbatim: manager.combo?.displayString ?? ""))
            if manager.combo != nil && !recording {
                Button { manager.set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear shortcut", comment: "VoiceOver label and tooltip of the x that removes the global shortcut."))
                .help(Text("Clear shortcut", comment: "VoiceOver label and tooltip of the x that removes the global shortcut."))
                .accessibilityIdentifier("settings-shortcut-clear")
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return String(localized: "Press shortcut…", comment: "Shown on the shortcut button while it waits for a key combination.") }
        if let combo = manager.combo { return combo.displayString }
        return String(localized: "Click to record", comment: "Shown on the shortcut button when no global shortcut is set.")
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        ShortcutRecorderState.shared.isRecording = true
        ShortcutRecorderState.shared.rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if event.keyCode == 53 && plain { stop(); return nil }                                   // Esc cancels
            if (event.keyCode == 51 || event.keyCode == 117) && plain { manager.set(nil); stop(); return nil } // Delete clears
            guard let combo = KeyCombo.make(keyCode: UInt32(event.keyCode), characters: event.charactersIgnoringModifiers,
                                            flags: event.modifierFlags) else { return nil }
            if combo.isValid {
                manager.set(combo)
                stop()
            } else {
                ShortcutRecorderState.shared.rejected = true   // keep recording
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        ShortcutRecorderState.shared.isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Tiny shared state so the hint row under the recorder can react to a rejected combination.
@MainActor
@Observable
final class ShortcutRecorderState {
    static let shared = ShortcutRecorderState()
    var rejected = false
    /// True while the recorder waits for a key combination (app shortcuts like ⌘W must not fire then).
    var isRecording = false
}

/// One-line hint under the recorder, only when needed.
struct ShortcutHint: View {
    private let manager = GlobalShortcutManager.shared
    private let state = ShortcutRecorderState.shared

    var body: some View {
        if state.rejected {
            line(String(localized: "Include ⌘, ⌃ or ⌥ in the shortcut.", comment: "Hint when a recorded shortcut has no ⌘, ⌃ or ⌥ modifier and was rejected."), color: .red)
        } else if manager.combo?.isLikelySystemShortcut == true {
            line(String(localized: "macOS may already use this combination.", comment: "Warning under the global shortcut when it matches a well-known system shortcut."), color: .orange)
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(verbatim: text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
