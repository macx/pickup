import AppKit
import Contacts
import CoreBluetooth
import Observation
import UserNotifications

/// Current state of the privacy permissions Pickup uses. Refresh when the app becomes active,
/// because the user may have changed them in System Settings.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var bluetooth: CBManagerAuthorization = CBManager.authorization
    private(set) var contacts: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var notifications: UNAuthorizationStatus = .notDetermined

    /// `UNUserNotificationCenter` aborts when the process is not an app bundle (e.g. `swift run`).
    nonisolated static var notificationsAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var contactsGranted: Bool {
        // `.limited` (rawValue 4) is not exposed by the macOS SDK (iOS-only symbol), even on macOS 26.
        contacts == .authorized || contacts.rawValue == 4
    }
    var notificationsGranted: Bool {
        notifications == .authorized || notifications == .provisional
    }
    var bluetoothDenied: Bool { bluetooth == .denied || bluetooth == .restricted }

    func refresh() async {
        bluetooth = CBManager.authorization
        contacts = CNContactStore.authorizationStatus(for: .contacts)
        if Self.notificationsAvailable {
            notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    @discardableResult
    func requestContacts() async -> Bool {
        guard !TestMode.isActive else { return false }   // no TCC prompts in tests
        let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        await refresh()
        return granted
    }

    @discardableResult
    func requestNotifications() async -> Bool {
        guard Self.notificationsAvailable, !TestMode.isActive else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        await refresh()
        return granted
    }

    static func openBluetoothPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }
    static func openContactsPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
    }
    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Caller-name lookup. Builds an in-memory index of all contact numbers once access is granted
/// (nothing is persisted) and matches by `PhoneNumberFormat.matchKey`.
@MainActor
@Observable
final class ContactsDirectory {
    struct Match: Equatable, Sendable {
        var name: String
        var imageData: Data?
    }

    private(set) var index: [String: Match] = [:]
    /// Searchable copy of the address book (memory only).
    private(set) var entries: [ContactEntry] = []
    /// Launch argument `-PickupDemoContacts yes|notDetermined|denied`: invented contacts or a forced
    /// permission state for screenshots, so real contacts are never shown.
    /// Any `-PickupDemo` launch uses invented contacts (or the forced state); real contacts are never read.
    nonisolated static var isDemoLaunch: Bool { TestMode.usesInventedContacts }
    let demoAccess: String? = UserDefaults.standard.string(forKey: "PickupDemoContacts")
        ?? (ContactsDirectory.isDemoLaunch ? "yes" : nil)
    @ObservationIgnored private var loading = false
    /// A change arrived while a load was running: load again afterwards.
    @ObservationIgnored private var reloadQueued = false
    @ObservationIgnored private(set) var hasLoaded = false
    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func match(for number: String) -> Match? {
        guard let key = PhoneNumberFormat.matchKey(number) else { return nil }
        return index[key]
    }

    /// (Re)builds the index when contact access is granted; does nothing otherwise.
    /// Loads once after access was granted; later changes arrive through `CNContactStoreDidChange`.
    func loadIfNeeded() { if !hasLoaded { reload() } }

    func reload() {
        guard demoAccess == nil else { return }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status.rawValue == 4 else { return }
        guard !loading else { reloadQueued = true; return }
        loading = true
        Task.detached(priority: .utility) {
            let (built, builtEntries) = Self.buildIndex()
            await MainActor.run {
                self.index = built
                self.entries = builtEntries
                self.hasLoaded = true
                self.loading = false
                if self.reloadQueued { self.reloadQueued = false; self.reload() }
            }
        }
    }

    nonisolated private static func buildIndex() -> ([String: Match], [ContactEntry]) {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var result: [String: Match] = [:]
        var entries: [ContactEntry] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            var name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            if name.isEmpty { name = contact.organizationName }
            guard !name.isEmpty else { return }
            let match = Match(name: name, imageData: contact.thumbnailImageData)
            let phones = contact.phoneNumbers.map { value in
                ContactEntry.Phone(
                    label: value.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                    number: value.value.stringValue)
            }
            entries.append(ContactEntry(id: contact.identifier, name: name, organization: contact.organizationName,
                                        phones: phones, imageData: contact.thumbnailImageData))
            for phone in contact.phoneNumbers {
                if let key = PhoneNumberFormat.matchKey(phone.value.stringValue), result[key] == nil {
                    result[key] = match
                }
            }
        }
        return (result, entries)
    }

    func search(_ query: String) -> [ContactSearchResult] {
        ContactSearch.search(query, in: entries)
    }

    /// Invented contacts for tests and screenshots (any test scenario or `-PickupDemo` launch).
    func loadDemo() {
        let mobile = String(localized: "mobile", comment: "Phone number label, e.g. in a contact row.")
        let work = String(localized: "work", comment: "Phone number label, e.g. in a contact row.")
        let home = String(localized: "home", comment: "Phone number label, e.g. in a contact row.")
        entries = [
            ContactEntry(id: "jane", name: "Jane Doe", phones: [.init(label: mobile, number: "+49 170 0000123")]),
            ContactEntry(id: "john", name: "John Roe", phones: [.init(label: mobile, number: "+49 171 0000456")]),
            // Very long name: layout test.
            ContactEntry(id: "long", name: "Prof. Dr. Hans-Joachim Müller-Lüdenscheidt von und zu Hohenlohe-Langenburg",
                         organization: "Gesellschaft für angewandte Systemintegration mbH",
                         phones: [.init(label: work, number: "+49 89 0000789")]),
            // Several numbers: one row per number.
            ContactEntry(id: "multi", name: "Max Mustermann", phones: [
                .init(label: mobile, number: "+49 170 0000111"),
                .init(label: work, number: "+49 30 0000222"),
                .init(label: home, number: "+49 40 0000333")]),
            // Diacritic folding (ø, å).
            ContactEntry(id: "oystein", name: "Øystein Åberg", phones: [.init(label: mobile, number: "+47 000 00 444")]),
        ]
        // Caller-name lookup (banner, HUD) uses the same invented data.
        index = [:]
        for entry in entries {
            for phone in entry.phones {
                if let key = PhoneNumberFormat.matchKey(phone.number) {
                    index[key] = Match(name: entry.name, imageData: nil)
                }
            }
        }
    }
}
