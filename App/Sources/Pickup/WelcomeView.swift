import AppKit
import SwiftUI

/// First-run and after-update window: what Pickup does and every permission it needs, each with its
/// state and the button that grants it.
struct WelcomeView: View {
    let reason: WelcomePolicy.Reason
    let model: AppModel
    let openSettings: () -> Void
    let close: () -> Void

    private var permissions: PermissionsModel { model.permissions }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
            Form {
                Section("On this Mac") {
                    phoneRow
                    bluetoothRow
                    contactsRow
                    notificationsRow
                }
                Section("On your phone") {
                    row(symbol: "iphone.gen3", color: .green,
                        title: Text("Phone calls and call history", comment: "Welcome window: title of the row about the permissions on the Android phone."),
                        detail: Text("In the phone’s Bluetooth settings, open this Mac and allow “Phone calls” and “Contacts and call history”. Without the call history, Pickup lists only the calls since it started.",
                                     comment: "Welcome window: what to allow on the Android phone (Pixel wording: Phone calls, Contacts and call history).")) {
                        EmptyView()
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 520)
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-window")
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    switch reason {
                    case .firstLaunch:
                        Text("Welcome to Pickup!", comment: "Headline of the welcome window at the first launch.")
                    case .updatedUnsigned:
                        Text("Pickup was updated", comment: "Title of the welcome window after an update of an unsigned build.")
                    }
                }
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                Group {
                    switch reason {
                    case .firstLaunch:
                        Text(
                            "Pickup controls the incoming and outgoing calls of your Android phone, much like Continuity does for the iPhone. The conversation stays on your phone. Check the permissions below once, then you’re ready.",
                             comment: "Welcome window text at the first launch. Continuity is Apple’s name for the iPhone feature; keep it.")
                    case .updatedUnsigned:
                        Text("Pickup isn’t signed by Apple yet, so macOS treats every update like a new app and may ask for its permissions again. Here you see them all at a glance.",
                             comment: "Welcome window text after an update of a build without an Apple Developer ID signature.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if reason == .firstLaunch && !WelcomePolicy.isDeveloperIDSigned {
                Text("Pickup isn’t signed by Apple yet. After an update, macOS may ask again; this window then helps you.",
                     comment: "Small note at the bottom of the welcome window for builds without an Apple Developer ID signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Text("Done", comment: "Button that closes the welcome window.")
                    .frame(minWidth: 72)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .accessibilityIdentifier("welcome-done")
        }
    }

    // MARK: Rows

    private var phoneRow: some View {
        row(symbol: "phone.fill", color: .green,
            title: Text("Phone"),
            detail: Text("Pair it in System Settings › Bluetooth first, then choose it in Pickup.",
                         comment: "Welcome window: how to set up the phone.")) {
            switch model.connection {
            case .connected(let name):
                granted(Text("Connected to \(name)"))
            case .noPhone:
                Button { openSettings() } label: {
                    Text("Choose Phone…")
                }
            case .connecting(let name), .reconnecting(let name), .disconnected(let name):
                Text(verbatim: name).foregroundStyle(.secondary)
            }
        }
    }

    private var bluetoothRow: some View {
        row(symbol: "wave.3.right", color: .blue,
            title: Text("Bluetooth"),
            detail: Text("Needed to connect to your phone.", comment: "Welcome window: why Pickup needs Bluetooth.")) {
            switch permissions.bluetooth {
            case .allowedAlways:
                granted(Text("Allowed"))
            case .notDetermined:
                Text("Asked when connecting", comment: "Welcome window: macOS asks for Bluetooth the first time Pickup connects to the phone.")
                    .foregroundStyle(.secondary)
            default:
                Button { PermissionsModel.openBluetoothPrivacySettings() } label: { Text("Open Settings…", comment: "Welcome window: button that opens the matching privacy pane in System Settings.") }
            }
        }
    }

    private var contactsRow: some View {
        row(symbol: "person.crop.circle.fill", color: .gray,
            title: Text("Contacts"),
            detail: Text("Shows names and photos and lets you search your contacts. Optional.",
                         comment: "Welcome window: why Pickup asks for Contacts access.")) {
            if permissions.contactsGranted {
                granted(Text("Allowed"))
            } else if permissions.contacts == .notDetermined {
                Button {
                    Task { if await permissions.requestContacts() { model.contacts.reload() } }
                } label: { Text("Allow", comment: "Welcome window: button that asks macOS for a permission.") }
                .accessibilityIdentifier("welcome-allow-contacts")
            } else {
                Button { PermissionsModel.openContactsPrivacySettings() } label: { Text("Open Settings…") }
            }
        }
    }

    private var notificationsRow: some View {
        row(symbol: "bell.badge.fill", color: .red,
            title: Text("Notifications"),
            detail: Text("Tells you about missed calls, with “Call Back”. Optional.",
                         comment: "Welcome window: why Pickup asks to send notifications.")) {
            if permissions.notificationsGranted {
                granted(Text("Allowed"))
            } else if permissions.notifications == .notDetermined {
                Button {
                    Task { await permissions.requestNotifications() }
                } label: { Text("Allow") }
                .accessibilityIdentifier("welcome-allow-notifications")
            } else {
                Button { PermissionsModel.openNotificationSettings() } label: { Text("Open Settings…") }
            }
        }
    }

    private func granted(_ text: Text) -> some View {
        Label { text } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
        }
        .foregroundStyle(.secondary)
    }

    /// Icon in a coloured rounded square (like System Settings), title, explanation and the state or
    /// action on the right.
    private func row<Trailing: View>(symbol: String, color: Color, title: Text, detail: Text,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.body)
                detail.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
    }
}
