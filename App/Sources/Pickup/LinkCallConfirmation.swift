import AppKit
import PickupCore
import SwiftUI

/// Confirmation for `tel:` / `callto:` links, shown immediately as a regular (non-modal) window.
///
/// Deliberately not `NSAlert.runModal()`: a modal session runs the run loop in a special mode in
/// which IOBluetooth callbacks (link coming up, call state) may not be delivered. This window
/// observes the live connection state, so the Call button enables itself once the link is up.
@MainActor
final class LinkCallConfirmation {
    static let shared = LinkCallConfirmation()
    private var window: NSWindow?

    /// `number == nil` shows the "invalid link" message instead.
    func present(number: DialNumber?, model: AppModel) {
        window?.close()
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        let close = { [weak window, weak self] in
            window?.close()
            if self?.window === window { self?.window = nil }
        }
        window.contentView = NSHostingView(rootView: LinkCallConfirmationView(number: number, model: model, close: close))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct LinkCallConfirmationView: View {
    let number: DialNumber?
    let model: AppModel
    let close: () -> Void
    @State private var error: String?
    /// Return is ignored until this is true (one second after the window appears).
    @State private var armed = false

    private var phone: String {
        model.selectedName ?? String(localized: "your phone", comment: "Fallback for the phone's name, used mid-sentence, e.g. \"Call audio is on your phone\".")
    }
    private var shown: String? { number.map { PhoneNumberFormat.display($0.value) } }
    private var contactName: String? { number.flatMap { model.contacts.match(for: $0.value)?.name } }

    /// Why the call cannot be placed right now; nil when it can.
    private var blocker: String? {
        if model.selectedAddress == nil {
            return String(localized: "Choose your phone in Settings first.", comment: "Shown in the phone-link confirmation when no phone is selected.")
        }
        if model.callIsLive { return CallEngineError.callInProgress.localizedText }
        if !model.connection.isConnected {
            return String(localized: "Waiting for your phone to connect…", comment: "Shown in the phone-link confirmation while the Bluetooth link is down; the Call button enables itself when it is up.")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let number, let shown {
                Text(contactName.map { String(localized: "Call \($0)?", comment: "Confirmation title for a tel: link. %@ is the contact name.") }
                     ?? String(localized: "Call \(shown)?", comment: "Confirmation title for a tel: link. %@ is the formatted phone number."))
                    .font(.headline)
                if number.isServiceCode {
                    Label(String(localized: "This link wants to send a service code (e.g. call forwarding) to your phone.",
                                 comment: "Strong warning in the confirmation window when a tel: link contains * or #. Such codes can change phone settings such as call forwarding."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text(String(localized: "Pickup will place this call on \(phone).",
                            comment: "Confirmation detail for a tel: link. %@ is the phone name, or \"your phone\"."))
                    .foregroundStyle(.secondary)
                if let message = error ?? blocker {
                    Text(verbatim: message).font(.callout).foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            } else {
                Text("This phone link cannot be used.").font(.headline)
                Text("The link does not contain a valid phone number.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if let number {
                    // A stray Return must never place a call: Return is ignored for the first second,
                    // and for service codes Cancel is the default button (Call needs a click).
                    if number.isServiceCode {
                        Button("Cancel", action: close).keyboardShortcut(.defaultAction)
                        Button(action: close) { EmptyView() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    } else {
                        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    }
                    Button("Call") {
                        error = model.dial(number, allowServiceCode: true) // confirmed here
                        if error == nil { close() }
                    }
                    .keyboardShortcut(armed && !number.isServiceCode ? KeyboardShortcut.defaultAction : nil)
                    .disabled(blocker != nil)
                } else {
                    Button("OK", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .task {
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
        .padding(20)
        .frame(width: 400)
    }
}
