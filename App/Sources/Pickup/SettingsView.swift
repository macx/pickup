import AppKit
import PickupBluetooth
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model = AppModel.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var loginError = false
    @State private var phones: [PairedPhone] = []
    @State private var showAllDevices = false
    private var linkHandler: LinkHandlerStatus { model.linkHandler }
    private var permissions: PermissionsModel { model.permissions }
    @AppStorage(MissedCallNotifier.enabledKey) private var notifyMissed = true

    var body: some View {
        Form {
            Section {
                phoneRow
                if let hint = phoneHint { hintLine(hint) }
                if permissions.bluetoothDenied {
                    LabeledContent {
                        Button("Privacy Settings…") { PermissionsModel.openBluetoothPrivacySettings() }
                    } label: {
                        Text("Bluetooth access is off for Pickup.").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Take calls on this Mac", isOn: .constant(false))
                    .disabled(true)
                    .accessibilityIdentifier("settings-take-calls")
                    .help(Text("Not available yet. For now, Pickup controls your calls from the Mac while the conversation stays on your phone."))
                Picker("Phone battery", selection: Binding(get: { model.batteryDisplay }, set: { model.batteryDisplay = $0 })) {
                    Text("In the menu window", comment: "Settings option for the phone's battery: gauge and percentage in the popover's status line.")
                        .tag(BatteryDisplay.popover)
                    Text("In the menu bar", comment: "Settings option for the phone's battery: percentage next to Pickup's menu bar icon.")
                        .tag(BatteryDisplay.menuBar)
                    Text("Don’t show", comment: "Settings option for the phone's battery: hidden.")
                        .tag(BatteryDisplay.off)
                }
                .accessibilityIdentifier("settings-battery")
                .help(Text("Your phone reports its charge in steps of 20 percent.", comment: "Tooltip of the phone battery setting."))
                LabeledContent("Global shortcut") { ShortcutRecorder() }
                    .help(Text("Opens Pickup's menu bar window from anywhere. Press it again to close it."))
                ShortcutHint()
            }
            Section {
                linksRow
                if let failure = linkHandler.failure { errorLine(failure) }
                if linkHandler.needsManualStep && !linkHandler.isDefault {
                    hintLine("If macOS does not accept the change, open FaceTime, choose Settings and select Pickup under “Default for calls”.")
                }
                contactsRow
                notificationsRow
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .accessibilityIdentifier("settings-launch-at-login")
                    .onChange(of: launchAtLogin) { _, newValue in
                        loginError = !LaunchAtLogin.set(newValue)
                        launchAtLogin = LaunchAtLogin.isEnabled
                        needsApproval = LaunchAtLogin.needsApproval
                    }
                if needsApproval {
                    LabeledContent {
                        Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Pickup needs your approval in System Settings > General > Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if loginError { errorLine(String(localized: "Could not change the login item setting.", comment: "Error caption shown when registering the login item failed.")) }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    // MARK: Phone

    private var visiblePhones: [PairedPhone] {
        phones.filter { showAllDevices || $0.isHandsFreeAudioGateway || $0.address == model.selectedAddress }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var phoneRow: some View {
        LabeledContent("Phone") {
            HStack(spacing: 8) {
                if model.selectedAddress != nil {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(verbatim: statusText).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Picker("Phone", selection: Binding(
                    get: { model.selectedAddress },
                    set: { address in
                        model.selectPhone(address: address, name: phones.first { $0.address == address }?.name)
                    })
                ) {
                    Text("None").tag(String?.none)
                    ForEach(visiblePhones) { phone in
                        Text(verbatim: phone.name).tag(String?.some(phone.address))
                    }
                    if let address = model.selectedAddress, !phones.contains(where: { $0.address == address }) {
                        Text(verbatim: model.selectedName ?? address).tag(String?.some(address))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings-phone-picker")
                Menu {
                    if model.selectedAddress != nil, !model.connection.isConnected {
                        Button("Reconnect") { model.reconnect() }
                    }
                    Toggle("Show all Bluetooth devices", isOn: $showAllDevices)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(Text("Phone options", comment: "VoiceOver label of the small menu next to the phone picker in Settings."))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Phone options", comment: "Tooltip of the small menu next to the phone picker in Settings."))
                .accessibilityIdentifier("settings-phone-options")
            }
        }
    }

    private var phoneHint: LocalizedStringKey? {
        visiblePhones.isEmpty && model.selectedAddress == nil ? "No phone found. Pair your phone in System Settings > Bluetooth first." : nil
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: .green
        case .connecting, .reconnecting: .secondary
        case .noPhone, .disconnected: .orange
        }
    }

    /// Short status; the phone's name is already in the picker.
    private var statusText: String {
        switch model.connection {
        case .noPhone: ""
        case .connected: String(localized: "Connected", comment: "Short connection status next to the phone picker in Settings.")
        case .connecting: String(localized: "Connecting…", comment: "Short connection status next to the phone picker while the link is being set up.")
        case .reconnecting: String(localized: "Reconnecting…", comment: "Short connection status next to the phone picker while Pickup retries.")
        case .disconnected: String(localized: "Not connected", comment: "Short connection status next to the phone picker when the link is down.")
        }
    }

    // MARK: Links, contacts, notifications

    private var linksRow: some View {
        LabeledContent("Phone links") {
            if linkHandler.isDefault {
                Label("Pickup", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help(Text("Pickup is the default for phone links (tel: and callto:)."))
            } else {
                HStack(spacing: 8) {
                    Text(verbatim: linkHandler.handlerName ?? String(localized: "None", comment: "Shown as the current app for phone links when no app handles them."))
                        .foregroundStyle(.secondary)
                    Button("Make Default") { Task { await linkHandler.makeDefault() } }
                        .accessibilityIdentifier("settings-make-default")
                        .help(Text("Clicking a phone number link in Safari, Contacts or other apps will then ask Pickup to call it on your phone."))
                }
            }
        }
    }

    private var contactsRow: some View {
        LabeledContent("Contacts") {   // identifiers: settings-contacts-button on the buttons below
            if permissions.contactsGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    .help(Text("Caller names come from your contacts."))
            } else if permissions.contacts == .notDetermined {
                Button("Allow…") {
                    Task { if await permissions.requestContacts() { model.contacts.reload() } }
                }
                .accessibilityIdentifier("settings-contacts-button")
                .help(Text("Pickup shows caller names and searches your contacts when you dial."))
            } else {
                Button("Privacy Settings…") { PermissionsModel.openContactsPrivacySettings() }
                    .help(Text("Pickup cannot read your contacts, so callers appear with their number."))
            }
        }
    }

    /// Toggle plus, only when the system permission is missing, a small button in the same row.
    private var notificationsRow: some View {
        LabeledContent("Missed call notifications") {
            HStack(spacing: 10) {
                if PermissionsModel.notificationsAvailable && !permissions.notificationsGranted {
                    if permissions.notifications == .notDetermined {
                        Button("Allow…") { Task { await permissions.requestNotifications() } }
                    } else {
                        Button("Notification Settings…") { PermissionsModel.openNotificationSettings() }
                            .help(Text("Notifications are off for Pickup in System Settings."))
                    }
                }
                Toggle("Missed call notifications", isOn: Binding(
                    get: { notifyMissed && (permissions.notificationsGranted || !PermissionsModel.notificationsAvailable) },
                    set: { on in
                        notifyMissed = on
                        if on && permissions.notifications == .notDetermined {
                            Task { await permissions.requestNotifications() }
                        }
                    }))
                    .labelsHidden()
                    // Inside LabeledContent a Toggle defaults to a checkbox; match the form's other switches.
                    .toggleStyle(.switch)
                    .disabled(PermissionsModel.notificationsAvailable && permissions.notifications == .denied)
                    .accessibilityIdentifier("settings-notifications-toggle")
            }
        }
    }

    private func refresh() {
        phones = TestMode.isActive ? [] : AppleHFPTransport.pairedPhones()   // no Bluetooth (TCC) in tests
        linkHandler.refresh()
        Task { await permissions.refresh() }
    }

    private func hintLine(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorLine(_ text: String) -> some View {
        StatusMessage(text: text, kind: .error, font: .caption)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns false if the system call failed.
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch { return false }
    }
}
