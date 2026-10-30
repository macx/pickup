import AppKit
import PickupCore
import SwiftUI

/// Launch-argument overrides for screenshots (never touch real contacts).
private enum DialerDemo {
    static var query: String { UserDefaults.standard.string(forKey: "PickupDemoQuery") ?? "" }
    static var keypadOpen: Bool { UserDefaults.standard.bool(forKey: "PickupDemoKeypad") }
    /// `-PickupDemoPressedKey 5`: shows that on-screen key as pressed (screenshots).
    static var pressedKey: String? { UserDefaults.standard.string(forKey: "PickupDemoPressedKey") }
}

/// Top bar (keypad toggle + search capsule), guidance, then keypad or result list.
struct DialerView: View {
    let model: AppModel
    /// Width between the popover's side margins (the popover's width is set by the user).
    let contentWidth: CGFloat
    let openSettings: () -> Void
    let close: () -> Void

    @State private var text = DialerDemo.query
    @State private var manuallyOpen = DialerDemo.keypadOpen
    /// The user folded away a keypad that had opened automatically for a number query.
    @State private var autoDismissed = false
    /// On-screen keys shown as pressed (physical key held, or still within the minimum display time).
    @State private var pressedKeys: Set<String> = DialerDemo.pressedKey.map { [$0] } ?? []
    @State private var pressTokens: [String: Int] = [:]
    @State private var holdUntil: [String: Date] = [:]
    /// A long press on 0 has inserted "+"; the button release that follows must not add a 0.
    @State private var longPressFired = false
    @State private var selectedID: String?
    @State private var error: String?
    /// Row whose service-code confirmation is pending (second Return/double-click dials it).
    @State private var pendingConfirmationID: String?
    /// The text exactly as the keypad produced it; any other edit (typing, paste) makes it untrusted.
    @State private var keypadText: String? = ""
    /// Tab of the recent calls shown while the field is empty (remembered between launches).
    @AppStorage("recentCallsList") private var recentListRaw = CallHistoryList.dialed.rawValue
    /// The tab was changed from the keyboard while a row was selected: select the new tab's first row.
    @State private var selectFirstRecentRow = false
    /// The skeleton rows were shown for `skeletonLimit`: a message replaces them until the list arrives.
    @State private var skeletonExpired = false
    private static let skeletonLimit: Duration = .seconds(10)
    /// Keyboard focus. Tab runs field → tabs → list in the system order (also without Full Keyboard
    /// Access); the tabs and the list are one focus stop each.
    private enum Focus: Hashable { case field, tabs, list }
    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Derived state

    private enum Access { case granted, notDetermined, denied }
    private var access: Access {
        switch model.contacts.demoAccess {
        case "yes": return .granted
        case "notDetermined": return .notDetermined
        case "denied": return .denied
        default:
            if model.permissions.contactsGranted { return .granted }
            return model.permissions.contacts == .notDetermined ? .notDetermined : .denied
        }
    }

    private var fromKeypad: Bool { text.isEmpty || text == keypadText }

    private var recentList: CallHistoryList { CallHistoryList(rawValue: recentListRaw) ?? .dialed }

    /// Search results, or the recent calls of the selected tab while the field is empty.
    private var rows: [DialerRow] {
        if queryIsEmpty {
            // The keypad takes the recent calls' place: hidden rows can never be selected or dialed.
            guard !showKeypad else { return [] }
            return DialerRows.recentRows(model.callHistory.entries(recentList), list: recentList)
        }
        return DialerRows.rows(for: text, contacts: model.contacts.search(text), fromKeypad: fromKeypad)
    }

    /// Number the keypad's call button puts into the empty field (redial).
    private var redialNumber: String? {
        DialerRows.redialNumber(in: model.callHistory.entries(.dialed))
    }

    /// The keypad's call button puts the last dialed number in instead of calling.
    private var keypadCallsRedial: Bool { queryIsEmpty && redialNumber != nil }

    private var keypadCallEnabled: Bool {
        model.canDial && (callRow != nil || (queryIsEmpty && redialNumber != nil))
    }

    private var callRow: DialerRow? {
        rows.first { if case .call = $0.kind { true } else { false } }
    }

    private var selectedIndex: Int {
        let rows = self.rows
        // Recent calls start without a selection, so a stray Return never redials.
        return rows.firstIndex { $0.id == selectedID } ?? (queryIsEmpty ? -1 : 0)
    }

    private var showKeypad: Bool {
        KeypadVisibility.resolve(text: text, manuallyOpen: manuallyOpen, autoDismissed: autoDismissed)
    }

    private var queryIsEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var unavailableReason: String? {
        if !model.connection.isConnected && !model.isDemo {
            return String(localized: "Connect your phone to place calls.", comment: "Short reason shown in the popover when no phone is connected and dialing is disabled.")
        }
        if model.callIsLive {
            return String(localized: "Finish the current call first.", comment: "Short reason shown in the popover while a call is live and dialing is disabled.")
        }
        return nil
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
                .frame(width: contentWidth)
            if let guidance = model.guidance {
                GuidanceCard(guidance: guidance, model: model, openSettings: openSettings)
            }
            if let notice = model.notice {
                StatusMessage(text: notice)
            }
            if let reason = unavailableReason, model.guidance == nil {
                Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
            }
            if showKeypad || queryIsEmpty {
                // Keypad and recent calls share one box of the keypad's height: toggling the keypad
                // cross-fades in place, and loading the calls never resizes the popover.
                ZStack(alignment: .top) {
                    if showKeypad {
                        keypad
                            .padding(.top, Self.keypadTopInset)
                            .transition(.opacity)
                    }
                    if queryIsEmpty && !showKeypad {
                        recentCalls.transition(.opacity)
                    }
                }
                .frame(width: contentWidth, height: Self.keypadHeight + Self.keypadTopInset, alignment: .top)
            }
            if !queryIsEmpty {
                content
                    .frame(width: contentWidth)
            }
            if let error {
                StatusMessage(text: error, kind: .error)
            }
        }
        .padding(.horizontal, Self.sideMargin)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .onAppear {
            focusFieldSoon()
            DialerKeyRouter.shared.move = { delta in moveSelection(delta) }
            DialerKeyRouter.shared.escape = { handleEscape() }
            DialerKeyRouter.shared.switchTab = { delta in
                guard let index = CallHistoryList.allCases.firstIndex(of: recentList) else { return false }
                return selectTab(index + delta)
            }
            DialerKeyRouter.shared.selectTab = { index in selectTab(index) }
            DialerKeyRouter.shared.submit = { submitSelectedRow() }
            DialerKeyRouter.shared.copy = { copySelectedNumber() }
            DialerKeyRouter.shared.typeText = { characters in typeIntoField(characters) }
            DialerKeyRouter.shared.physicalKey = { key, down in physicalKey(key, down: down) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pickupPopoverWillShow)) { _ in
            text = DialerDemo.query
            keypadText = DialerDemo.query.isEmpty ? "" : nil
            manuallyOpen = DialerDemo.keypadOpen
            autoDismissed = false
            pressedKeys = DialerDemo.pressedKey.map { [$0] } ?? []
            error = nil
            selectedID = nil
            pendingConfirmationID = nil
            if model.hasUnseenMissedCalls {
                recentListRaw = CallHistoryList.missed.rawValue   // the red dot led here
                model.markMissedCallsSeen()
            }
            model.refreshCallHistory()
            focusFieldSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pickupPopoverDidShow)) { _ in focusFieldSoon() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showKeypad)
        .onChange(of: text) { _, new in
            if !KeypadVisibility.isDialQuery(new) { autoDismissed = false }
            error = nil
            selectedID = nil
            pendingConfirmationID = nil
        }
        .onChange(of: focus) { _, new in
            switch new {
            case .field:
                collapseCaret()
            case .list:
                // Entering the list (Tab, ↓ from the tabs) selects its first row, so Return calls it.
                let rows = self.rows
                if !rows.contains(where: { $0.id == selectedID }), let first = rows.first {
                    selectedID = first.id
                    announceSelection(first)
                }
            case .tabs, nil:
                if queryIsEmpty { selectedID = nil }   // Return goes to the focused control now, not to a recent call
            }
        }
        .onChange(of: showKeypad) { _, _ in
            if queryIsEmpty { selectedID = nil; pendingConfirmationID = nil }
        }
        .onChange(of: model.callHistory.entries(recentList)) { old, new in
            // Row IDs are positions: when the phone's list changes under a selected row, that row may now be
            // another caller. Drop the selection (and a pending service-code confirmation) unless it is the same.
            guard queryIsEmpty, let id = selectedID ?? pendingConfirmationID, id.hasPrefix("recent|"),
                  let index = id.split(separator: "|").last.flatMap({ Int($0) }) else { return }
            if !old.indices.contains(index) || !new.indices.contains(index) || old[index] != new[index] {
                selectedID = nil
                pendingConfirmationID = nil
            }
        }
        .onChange(of: recentListRaw) { _, _ in
            pendingConfirmationID = nil
            error = nil
            let keepSelection = selectFirstRecentRow
            selectFirstRecentRow = false
            selectedID = keepSelection ? rows.first?.id : nil
        }
    }

    /// The window is not key yet when the popover is about to open; focus the field once it is.
    private func focusFieldSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            focus = .field
            collapseCaret()
        }
    }

    /// Focusing a text field selects its content. Once focus has landed, collapse the selection to the
    /// end (set directly on the field editor, on the next run-loop turns so SwiftUI has finished).
    private func collapseCaret() {
        for delay in [0.0, 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    /// Esc: back to the search field from the tabs, the list or a selected row first, then clear the
    /// field; with an empty field the popover closes (return false).
    private func handleEscape() -> Bool {
        if focus == .tabs || focus == .list || (queryIsEmpty && selectedID != nil) {
            leaveList()
            return true
        }
        guard !text.isEmpty else { return false }
        text = ""
        keypadText = ""
        return true
    }

    /// Switches the recent calls tab from the keyboard (only while the field is empty). A selected
    /// row moves to the first row of the new tab; VoiceOver hears the tab and that row.
    private func selectTab(_ index: Int) -> Bool {
        guard queryIsEmpty else { return false }
        let lists = CallHistoryList.allCases
        let target = lists[min(max(index, 0), lists.count - 1)]
        guard target != recentList else { return true }
        let wasInList = rows.contains { $0.id == selectedID }
        selectFirstRecentRow = wasInList
        recentListRaw = target.rawValue
        let newRows = DialerRows.recentRows(model.callHistory.entries(target), list: target)

        let detail = wasInList ? newRows.first.map(selectionText) : nil
        let tabName = target.localizedTabName
        announce(newRows.isEmpty
            ? String(localized: "\(tabName) tab, no calls", comment: "VoiceOver announcement when the recent calls tab is switched from the keyboard and the tab is empty. %@ is the tab name, e.g. \"Missed\".")
            : detail.map { String(localized: "\(tabName) tab, \($0)", comment: "VoiceOver announcement when the recent calls tab is switched from the keyboard. First %@ is the tab name, second the selected row, e.g. \"Jane Doe, selected\".") }
                ?? String(localized: "\(tabName) tab", comment: "VoiceOver announcement when the recent calls tab is switched from the keyboard. %@ is the tab name, e.g. \"Missed\"."))
        return true
    }

    /// VoiceOver text for a selected row: name (or number) and details.
    private func selectionText(_ row: DialerRow) -> String {
        let display = row.display(contacts: model.contacts)
        if let subtitle = display.subtitle {
            return String(localized: "\(display.title), \(subtitle), selected", comment: "VoiceOver announcement when a row of the popover's list is selected with the keyboard. First %@ is the name or number, second the details (number, time).")
        }
        return String(localized: "\(display.title), selected", comment: "VoiceOver announcement when a row of the popover's list is selected with the keyboard. %@ is the name or number.")
    }

    /// The text field or the list keeps keyboard focus while rows are selected, so VoiceOver is told explicitly.
    private func announceSelection(_ row: DialerRow) {
        announce(selectionText(row))
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func leaveList() {
        selectedID = nil
        pendingConfirmationID = nil
        error = nil
        focus = .field
        collapseCaret()
    }

    // MARK: Top bar

    /// No `GlassEffectContainer` here: the button and the capsule are exactly the container's blend
    /// distance apart, so toggling the button made the glass merge and the capsule visibly shift.
    private var topBar: some View {
        HStack(spacing: 8) {
                Button(action: toggleKeypad) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showKeypad ? Color.white : Color.primary)
                        .frame(width: 34, height: 34)
                        // One glass whose tint changes (no swap of glass variants), and no interactive
                        // press bounce: the button keeps its size and place when it is toggled.
                        .glassEffect(.regular.tint(showKeypad ? .accentColor : nil), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(SteadyPressStyle())
                // Like Apple's toolbar buttons: no focus ring, except for Full Keyboard Access users.
                .focusEffectDisabled(!NSApp.isFullKeyboardAccessEnabled)
                .accessibilityLabel(Text("Keypad"))
                .accessibilityAddTraits(showKeypad ? [.isToggle, .isSelected] : .isToggle)
                .help(Text(showKeypad ? "Hide Keypad" : "Keypad"))
                .accessibilityIdentifier("keypad-toggle")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search", text: $text)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .field)
                        .onSubmit(submitFromReturn)
                        .accessibilityIdentifier("search-field")
                        .accessibilityLabel(Text("Search contacts or enter a number", comment: "VoiceOver label of the popover's search field."))
                    if !text.isEmpty {
                        Button { text = ""; keypadText = ""; focus = .field } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear"))
                        .help(Text("Clear"))
                        .accessibilityIdentifier("search-clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassEffect(.regular, in: Capsule())
        }
    }

    private func toggleKeypad() {
        if showKeypad {
            // Closing: a manually opened keypad is simply closed; an automatic one stays closed while
            // the text remains a number.
            manuallyOpen = false
            autoDismissed = KeypadVisibility.isDialQuery(text)
        } else {
            manuallyOpen = true
        }
        focus = .field
    }

    // MARK: Keypad

    static let keySize: CGFloat = 60
    /// Margin on both sides. Every block of the dialer gets exactly `contentWidth`: a child with a
    /// larger ideal width (the native segmented control in German, a legacy scroller) used to widen the
    /// popover's content and shift it sideways.
    static let sideMargin: CGFloat = 16
    static let keyColumnSpacing: CGFloat = 16
    static let keyRowSpacing: CGFloat = 12
    /// Height of the keypad (four rows of keys and the call button); the recent calls take the same.
    static let keypadHeight: CGFloat = 5 * keySize + 4 * keyRowSpacing
    static let callButtonSize: CGFloat = 28
    /// Extra room between the search bar and the first row of keys.
    static let keypadTopInset: CGFloat = 10

    private static let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    /// One glass key. The tap inserts the digit; a long press on "0" inserts "+" instead.
    @ViewBuilder
    private func keypadKey(_ key: String) -> some View {
        let pressed = pressedKeys.contains(key)
        let plus = KeypadKey.longPressValue(for: key)
        Button {
            if plus != nil && longPressFired { longPressFired = false; return }   // the long press already inserted "+"
            appendKey(key)
        } label: {
            VStack(spacing: -2) {
                Text(verbatim: key)
                    .font(.system(size: 24, weight: .regular, design: .rounded))
                if let glyph = KeypadKey.secondaryGlyph(for: key) {
                    Text(verbatim: glyph).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("key-plus")
                }
            }
            .frame(width: Self.keySize, height: Self.keySize)
            // Plain glass: the interactive variant stretches the key into an oval while it is pressed.
            .glassEffect(.regular, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(KeyPressStyle(highlighted: pressed, reduceMotion: reduceMotion))
        .accessibilityLabel(Text(verbatim: key))
        .accessibilityIdentifier(Self.identifier(forKey: key))
        .modifier(PlusLongPress(enabled: plus != nil) {
            longPressFired = true
            if let plus { appendKey(plus) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(3)); longPressFired = false }   // drag-off safety
        } accessibilityInsert: {
            if let plus { appendKey(plus) }
        })
    }

    /// UI-test identifier of a keypad key: key-0 ... key-9, key-star, key-hash.
    static func identifier(forKey key: String) -> String {
        switch key {
        case "*": "key-star"
        case "#": "key-hash"
        default: "key-\(key)"
        }
    }

    private var keypad: some View {
        GlassEffectContainer(spacing: Self.keyRowSpacing) {
            VStack(spacing: Self.keyRowSpacing) {
                ForEach(Self.keys, id: \.self) { row in
                    HStack(spacing: Self.keyColumnSpacing) {
                        ForEach(row, id: \.self) { key in
                            keypadKey(key)
                        }
                    }
                }
                Button(action: placeTypedCall) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: Self.keySize, height: Self.keySize)
                        .glassEffect(.regular.tint(.callGreen), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(KeyPressStyle(reduceMotion: reduceMotion))
                .disabled(!keypadCallEnabled)
                .opacity(keypadCallEnabled ? 1 : 0.45)
                .accessibilityLabel(keypadCallsRedial ? Text("Redial", comment: "Label of the keypad's call button while the field is empty: it puts the last dialed number in.") : Text("Call"))
                .help(keypadCallsRedial ? Text("Redial") : Text("Call"))
                .accessibilityIdentifier("keypad-call")
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var content: some View {
        let rows = self.rows
        let hasLetters = text.contains(where: \.isLetter)
        if rows.isEmpty {
            if access == .granted || !hasLetters {
                Text("No matches").font(.callout).foregroundStyle(Color.rowSubtitle).frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            if access != .granted && hasLetters { accessHint }
        } else {
            resultList(rows)
            if access != .granted && hasLetters { accessHint }
        }
    }

    /// `fill`: take the height the parent offers (recent calls) instead of growing with the rows.
    private func resultList(_ rows: [DialerRow], fill: Bool = false) -> some View {
        let selected = selectedIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button { selectedID = row.id } label: {
                            ResultRow(row: row.display(contacts: model.contacts), selected: index == selected,
                                      enabled: model.canDial, trailingInset: row.isRecent ? Self.callButtonSize + 8 : 0)
                        }
                        .buttonStyle(.plain)
                        // Rows never take keyboard focus: the list is one focus stop and the selection
                        // outline its only indicator (a second, system focus ring looked like two selections).
                        .focusable(false)
                        .disabled(!model.canDial)
                        .id(row.id)
                        .accessibilityIdentifier(row.testIdentifier)
                        // Single click selects; double-click or Return calls (a stray click never dials).
                        .simultaneousGesture(TapGesture(count: 2).onEnded { activate(row) })
                        .accessibilityAction(.default) { activate(row) }
                        .accessibilityHint(Text("Double-click or press Return to call.", comment: "VoiceOver hint of a search result row in the popover."))
                        .contextMenu { rowMenu(row) }
                        .overlay(alignment: .trailing) {
                            if row.isRecent { recentCallButton(row) }
                        }
                    }
                }
            }
            // Fixed width: with a mouse attached, macOS shows a legacy scroller that widened the list
            // by its width, pushed the popover's content 5 pt to the left and made it jump when the
            // keypad (no scroller) replaced the list.
            .frame(width: contentWidth)
            .frame(maxHeight: fill ? .infinity : (showKeypad ? 3 : 6) * 50, alignment: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)   // rows fade out at the bottom instead of being cut
            // One focus stop for the whole list: ↑/↓ select, Return calls, ⌘C copies. The selected row's
            // outline is the focus indicator (no second system ring).
            .focusable(interactions: .edit)
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            .accessibilityLabel(queryIsEmpty
                ? Text("Recent Calls")
                : Text("Search Results", comment: "VoiceOver label of the list of contacts and numbers matching the popover's search field."))
            .onChange(of: selectedID) { _, new in
                if let new { proxy.scrollTo(new) }
            }
        }
    }

    /// The call button at the end of a recent call row: one click dials (a service code asks first).
    private func recentCallButton(_ row: DialerRow) -> some View {
        let dialable = row.recentNumber != nil && model.canDial
        let title = row.display(contacts: model.contacts).title
        let label = row.recentNumber == nil ? String(localized: "Call") : String(localized: "Call \(title)")
        return Button { selectedID = row.id; activate(row) } label: {
            Image(systemName: "phone.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: Self.callButtonSize, height: Self.callButtonSize)
                .background(Color.callGreen, in: Circle())
                .frame(width: Self.callButtonSize + 12, height: Self.callButtonSize + 12)   // larger hit area than the circle
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)   // Return calls the selected row; one Tab stop per row would make the list a long detour
        .disabled(!dialable)
        .opacity(dialable ? 1 : 0.35)
        .padding(.trailing, 2)   // circle 8 pt from the row's edge, like the avatar on the left
        .accessibilityLabel(Text(verbatim: label))
        .help(Text(verbatim: label))
        .accessibilityIdentifier(row.testIdentifier + "-call")
    }

    @ViewBuilder
    private func rowMenu(_ row: DialerRow) -> some View {
        Button("Call") { selectedID = row.id; activate(row) }
            .disabled(!model.canDial)
        Button {
            copy(row)
        } label: {
            Text("Copy Number", comment: "Context menu item of a row in the popover's list: copies the phone number.")
        }
        .disabled(row.copyableNumber == nil)
        if let card = row.newContact(contacts: model.contacts) {
            Button {
                if !ContactCard.open(name: card.name, number: card.number) {
                    error = String(localized: "The contact could not be handed to your contacts app.",
                                   comment: "Inline error when Pickup could not open the new contact card in the contacts app.")
                }
            } label: {
                if let app = ContactCard.appName {
                    Text("Add to \(app)…", comment: "Context menu item of a recent call or typed number without a contact: opens the contacts app (e.g. Contacts or Cardhop) with a new contact. %@ is the app name.")
                } else {
                    Text("Add to Contacts…", comment: "Context menu item of a recent call or typed number without a contact, when the name of the contacts app is unknown.")
                }
            }
        }
    }

    // MARK: Recent calls

    private var recentCalls: some View {
        let history = model.callHistory
        let rows = self.rows
        return VStack(spacing: 8) {
            RecentCallsTabs(selection: $recentListRaw, focused: focus == .tabs)
                .focusable(interactions: .edit)
                .focused($focus, equals: .tabs)
                .focusEffectDisabled()   // RecentCallsTabs draws its own ring
                .accessibilityIdentifier("recent-tabs")
                .accessibilityHint(Text("Use the left and right arrow keys or Command-1 to 3 to switch tabs.", comment: "VoiceOver hint of the recent calls tabs in the popover."))

            Group {
                if !rows.isEmpty {
                    resultList(rows, fill: true)
                } else if history.isLoading && !skeletonExpired {
                    // First read after launch: placeholder rows in the shape of the real ones, so the list
                    // fades in where they were (nothing jumps). Nothing is saved on the Mac between launches.
                    RecentCallsSkeleton(trailingInset: Self.callButtonSize + 8, callButtonSize: Self.callButtonSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .task {
                            try? await Task.sleep(for: Self.skeletonLimit)
                            if !Task.isCancelled { skeletonExpired = true }
                        }
                } else if history.isLoading || history.lastReadUnanswered {
                    Text("Recent calls aren’t available right now.", comment: "Shown instead of the recent calls when the phone has not sent them within 10 seconds or did not answer.")
                        .font(.callout).foregroundStyle(Color.rowSubtitle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No calls", comment: "Empty state of a recent calls tab in the popover.")
                        .font(.callout).foregroundStyle(Color.rowSubtitle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: rows.isEmpty)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: history.isLoading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: skeletonExpired)
            .onChange(of: history.isLoading) { _, loading in
                if !loading { skeletonExpired = false }   // the next read shows the skeleton again
            }
            if history.source(recentList) == .session && !history.isLoading && history.phoneRefused {
                Text("Calls since Pickup started. To see your phone's call history, allow access to contacts and call history in the phone's Bluetooth settings.",
                     comment: "Footnote below the recent calls when the phone did not share its call history and Pickup shows its own list.")
                    .font(.caption).foregroundStyle(Color.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)   // aligned with the rows' content
            }
            if access != .granted { accessHint }
        }
    }

    @ViewBuilder
    private var accessHint: some View {
        if access == .notDetermined {
            Button("Allow access to search contacts") {
                Task { if await model.permissions.requestContacts() { model.contacts.reload() } }
            }
            .controlSize(.small)
        } else if access == .denied {
            Button("Open Contacts Privacy Settings…") { PermissionsModel.openContactsPrivacySettings() }
                .controlSize(.small)
        }
    }

    // MARK: Physical key feedback

    /// Minimum time a pressed key stays highlighted, so quick taps are visible. When the keypad is
    /// still folded the press also lights the key right after the keypad has appeared.
    private func physicalKey(_ key: String, down: Bool) {
        if down {
            guard !pressedKeys.contains(key) else { return }      // ignore auto-repeat
            let token = (pressTokens[key] ?? 0) + 1
            pressTokens[key] = token
            pressedKeys.insert(key)
            holdUntil[key] = Date().addingTimeInterval(showKeypadAfterPress ? 0.12 : 0.40)
        } else {
            let remaining = max(0, (holdUntil[key] ?? .distantPast).timeIntervalSinceNow)
            let token = pressTokens[key]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
                if pressTokens[key] == token { pressedKeys.remove(key) }
            }
        }
    }

    /// True when the keypad is already visible at key-down (so the highlight is seen immediately).
    private var showKeypadAfterPress: Bool { showKeypad }

    // MARK: Actions

    private func appendKey(_ key: String) {
        text.append(key)
        keypadText = text
        focus = .field
        collapseCaret()
    }

    private func moveSelection(_ delta: Int) -> Bool {
        let rows = self.rows
        guard !rows.isEmpty else { return false }
        if focus == .tabs {
            guard delta > 0 else { return false }
            focus = .list   // ↓ from the tabs enters the list at its first row
            return true
        }
        let index = min(max(selectedIndex + delta, 0), rows.count - 1)
        if selectedID != rows[index].id { announceSelection(rows[index]) }
        selectedID = rows[index].id
        if focus != .list { focus = .field }   // arrow keys bring keyboard focus back from any button to the field
        return true
    }

    /// ⌘C on a selected row copies its number. A search text in the field keeps the normal copy.
    private func copySelectedNumber() -> Bool {
        guard focus != .tabs, focus != .field || queryIsEmpty else { return false }
        let rows = self.rows
        guard rows.indices.contains(selectedIndex), rows[selectedIndex].copyableNumber != nil else { return false }
        copy(rows[selectedIndex])
        return true
    }

    private func copy(_ row: DialerRow) {
        guard let number = row.copyableNumber else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(number, forType: .string)
        announce(String(localized: "Number copied", comment: "VoiceOver announcement after a phone number from the popover's list was copied with Command-C or the context menu."))
    }

    /// Typing while the tabs or the list have focus continues the search in the field.
    private func typeIntoField(_ characters: String) -> Bool {
        guard focus == .tabs || focus == .list, TypeAhead.accepts(characters) else { return false }
        text.append(characters)
        focus = .field
        collapseCaret()
        return true
    }

    /// Return with an explicitly selected row (arrow keys, Tab, click): call it. Handled in the key
    /// monitor, so it works even when keyboard focus is not in the text field.
    private func submitSelectedRow() -> Bool {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return false }
        activate(row)
        return true
    }

    /// `onSubmit` can also fire when the field loses focus; only a real Return/Enter key press may dial.
    private func submitFromReturn() {
        guard let event = NSApp.currentEvent, event.type == .keyDown, [36, 76].contains(event.keyCode) else { return }
        let rows = self.rows
        if rows.indices.contains(selectedIndex) { activate(rows[selectedIndex]) }
    }

    /// The keypad's call button. With an empty field it puts the last dialed number in (redial);
    /// the next press calls it.
    private func placeTypedCall() {
        if queryIsEmpty, let number = redialNumber {
            text = number
            keypadText = nil   // came from the phone, not from the keypad: service codes need a confirmation
            focus = .field
            collapseCaret()
            return
        }
        if let row = callRow { activate(row) }
    }

    private func activate(_ row: DialerRow) {
        guard model.canDial else { error = unavailableReason; return }
        let number: DialNumber
        switch row.kind {
        case .call(let n): number = n
        case .contact(let result):
            guard let n = DialNumber(result.number) else {
                error = String(localized: "This number cannot be dialed.", comment: "Inline error when a contact's number is not a valid phone number.")
                return
            }
            number = n
        case .recent(_, let n, _):
            guard let n else {
                error = String(localized: "This number cannot be dialed.", comment: "Inline error when a contact's number is not a valid phone number.")
                return
            }
            number = n
        }
        if row.requiresConfirmation && pendingConfirmationID != row.id {
            pendingConfirmationID = row.id
            error = String(localized: "This is a service code (for example call forwarding). Press Return again to send it to your phone.",
                           comment: "Inline warning in the popover when typed or pasted text is a service code containing * or #. A second Return confirms.")
            return
        }
        if let message = model.dial(number, allowServiceCode: row.allowServiceCode || row.requiresConfirmation) {
            error = message
        } else {
            text = ""
            keypadText = ""
            manuallyOpen = false
            close()   // the call window takes over
        }
    }
}

/// Lets the popover's key monitor (see `StatusItemController`) drive the dialer without relying on
/// SwiftUI delivering arrow keys and Esc through the text field's field editor.
@MainActor
final class DialerKeyRouter {
    static let shared = DialerKeyRouter()
    var move: ((Int) -> Bool)?
    var escape: (() -> Bool)?
    /// Left/right arrow: previous/next recent calls tab (only while the field is empty).
    var switchTab: ((Int) -> Bool)?
    /// ⌘1 to ⌘3: recent calls tab by position.
    var selectTab: ((Int) -> Bool)?
    /// Return/Enter: calls the selected row, whichever control has keyboard focus; false = no row selected.
    var submit: (() -> Bool)?
    /// ⌘C: copies the selected row's number; false = the system copy applies.
    var copy: (() -> Bool)?
    /// Printable text typed while the tabs or the list have focus; true = it went to the search field.
    var typeText: ((String) -> Bool)?
    /// A physical dial key (0-9 * #) went down/up; drives the on-screen key highlight.
    var physicalKey: ((String, Bool) -> Void)?
}

// MARK: - Rows

extension CallHistoryList {
    /// Name of the recent calls tab.
    var localizedTabName: String {
        switch self {
        case .dialed: String(localized: "Outgoing", comment: "Tab of the recent calls in the popover: calls placed from the phone.")
        case .received: String(localized: "Incoming", comment: "Tab of the recent calls in the popover: answered incoming calls.")
        case .missed: String(localized: "Missed", comment: "Tab of the recent calls in the popover: missed incoming calls.")
        }
    }
}

fileprivate extension DialerRow {
    /// UI-test identifier: `call-row`, `contact-row-<contact id>-<number index>` or `recent-row-<list>-<index>`.
    var testIdentifier: String {
        switch kind {
        case .call: "call-row"
        case .contact: "contact-row-" + id.replacingOccurrences(of: "|", with: "-")
        case .recent: id.replacingOccurrences(of: "recent|", with: "recent-row-").replacingOccurrences(of: "|", with: "-")
        }
    }

    var isRecent: Bool { if case .recent = kind { true } else { false } }

    var recentNumber: DialNumber? { if case .recent(_, let number, _) = kind { number } else { nil } }

    /// Name and number for "Add to Contacts…": a recent call or typed number that matches no contact
    /// on this Mac. nil for contacts and withheld callers.
    @MainActor
    func newContact(contacts: ContactsDirectory) -> (name: String?, number: String)? {
        switch kind {
        case .recent(let entry, _, _):
            guard !entry.number.isEmpty, contacts.match(for: entry.number) == nil else { return nil }
            return (entry.name, entry.number)
        case .call(let number):
            guard !number.isServiceCode, contacts.match(for: number.value) == nil else { return nil }
            return (nil, number.value)
        case .contact:
            return nil
        }
    }

    @MainActor
    func display(contacts: ContactsDirectory) -> ResultRow.Display {
        switch kind {
        case .recent(let entry, _, let list):
            // The Mac's contact (with photo) wins over the name the phone sent.
            let match = entry.number.isEmpty ? nil : contacts.match(for: entry.number)
            let name = match?.name ?? entry.name
            let formatted = entry.number.isEmpty ? nil : PhoneNumberFormat.display(entry.number)
            let title = name ?? formatted
                ?? String(localized: "Unknown caller")
            var details: [String] = []
            if name != nil, let formatted { details.append(formatted) }
            if let date = entry.date { details.append(date.formatted(.relative(presentation: .named))) }
            if entry.count > 1 {
                details.append(String(localized: "\(entry.count) calls", comment: "Recent calls row: number of consecutive calls with the same number merged into this row, e.g. \"3 calls\"."))
            }
            return .init(title: title, subtitle: details.isEmpty ? nil : details.joined(separator: " · "),
                         party: CallParty(displayName: name, number: formatted, avatarPNG: match?.imageData),
                         isCall: false, warning: false, isMissed: list == .missed)
        default:
            return display
        }
    }

    private var display: ResultRow.Display {
        switch kind {
        case .call(let number):
            .init(title: String(localized: "Call \(PhoneNumberFormat.display(number.value))",
                                comment: "First result row when the typed text is a valid number. %@ is the formatted number."),
                  subtitle: requiresConfirmation
                      ? String(localized: "Service code", comment: "Warning subtitle on the call row when the text is a service code (contains * or #), e.g. call forwarding.")
                      : nil,
                  party: nil, isCall: true, warning: requiresConfirmation, isMissed: false)
        case .contact(let result):
            .init(title: result.name,
                  subtitle: [result.label, PhoneNumberFormat.display(result.number)].compactMap { $0 }.joined(separator: " · "),
                  party: CallParty(displayName: result.name, number: nil, avatarPNG: result.imageData),
                  isCall: false, warning: false, isMissed: false)
        case .recent:
            .init(title: "", subtitle: nil, party: nil, isCall: false, warning: false, isMissed: false)
        }
    }
}

private struct ResultRow: View {
    struct Display {
        var title: String; var subtitle: String?; var party: CallParty?; var isCall: Bool; var warning: Bool
        /// Missed calls are titled in red, like in the Phone app.
        var isMissed: Bool
    }
    let row: Display
    let selected: Bool
    let enabled: Bool
    /// Room kept free at the end for a button laid over the row.
    var trailingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            if row.isCall {
                Image(systemName: row.warning ? "exclamationmark.triangle.fill" : "phone.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(row.warning ? Color.warningOrange : Color.callGreen, in: Circle())
                    .accessibilityHidden(true)
            } else if let party = row.party {
                AvatarView(party: party, size: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title).font(.body).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(row.isMissed ? Color.missedRed : Color.primary)
                if let subtitle = row.subtitle {
                    Text(verbatim: subtitle).font(.caption)
                        .foregroundStyle(Color.rowSubtitle).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8 + trailingInset)
        .frame(height: 48)
        .background(selected ? Color.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.selectionRing, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Placeholder rows while the recent calls are read for the first time (like PrimeNG's Skeleton):
/// avatar, name and detail bars and the call button's circle, with a light sweeping across. Static
/// with Reduce Motion. VoiceOver hears one "Loading recent calls" element.
private struct RecentCallsSkeleton: View {
    let trailingInset: CGFloat
    let callButtonSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Varying bar lengths, so the placeholder reads as a list and not as a pattern.
    private static let widths: [(title: CGFloat, detail: CGFloat)] = [
        (0.55, 0.38), (0.42, 0.30), (0.62, 0.44), (0.48, 0.34), (0.58, 0.40), (0.45, 0.32),
    ]

    var body: some View {
        rows(Color.skeleton)
            .overlay {
                // The band is cut to the shapes drawn opaque: a mask also takes over the opacity, and the
                // faint shapes themselves let almost none of the band through.
                if !reduceMotion { ShimmerBand().mask(rows(.black)) }
            }
            .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading recent calls", comment: "VoiceOver label of the placeholder rows shown while the recent calls are read from the phone."))
        .accessibilityIdentifier("recent-skeleton")
    }

    private func rows(_ fill: Color) -> some View {
        VStack(spacing: 2) {
            ForEach(Self.widths.indices, id: \.self) { index in
                row(Self.widths[index], fill: fill)
            }
        }
    }

    private func row(_ widths: (title: CGFloat, detail: CGFloat), fill: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(fill).frame(width: 32, height: 32)
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(fill).frame(width: proxy.size.width * widths.title, height: 10)
                    Capsule().fill(fill).frame(width: proxy.size.width * widths.detail, height: 8)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            Circle().fill(fill).frame(width: callButtonSize, height: callButtonSize)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8 + 2)
        .frame(height: 48)
    }
}

/// A light band sweeping from left to right (PrimeNG's "wave": 1.2 s, endless). Driven by the clock,
/// not by a started animation: a repeating animation begun while the popover was still opening was
/// dropped and the band stood still.
private struct ShimmerBand: View {
    private static let period: TimeInterval = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            GeometryReader { proxy in
                let band = proxy.size.width * 0.5
                LinearGradient(colors: [.clear, Color.skeletonHighlight, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + progress * (proxy.size.width + band))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Long press (about 0.4 s, mouse included) plus an accessibility action for keys with a second function.
private struct PlusLongPress: ViewModifier {
    let enabled: Bool
    let onLongPress: () -> Void
    let accessibilityInsert: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .simultaneousGesture(LongPressGesture(minimumDuration: KeypadKey.longPressDuration).onEnded { _ in onLongPress() })
                .accessibilityAction(named: Text("Insert plus sign", comment: "VoiceOver custom action of the 0 key on the keypad: inserts a + (also reachable by long press).")) { accessibilityInsert() }
        } else {
            content
        }
    }
}

/// A round key: darkens and shrinks evenly (stays a circle) while the mouse is down or the matching
/// physical key is held.
private struct KeyPressStyle: ButtonStyle {
    var highlighted = false
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = highlighted || configuration.isPressed
        configuration.label
            .overlay(Circle().fill(Color.primary.opacity(pressed ? 0.22 : 0)).allowsHitTesting(false))
            .scaleEffect(pressed ? 0.93 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
    }
}

/// Pressed feedback without moving anything: the label only dims while the mouse is down.
private struct SteadyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Tabs above the recent calls: equal segments that always fill the given width exactly. The native
/// segmented control sizes itself from its labels and grew wider than the popover with the German
/// texts, which shifted the whole content. VoiceOver still gets a real segmented picker.
private struct RecentCallsTabs: View {
    @Binding var selection: String
    /// Keyboard focus is on the tabs (←/→ switch): drawn as a ring around the control.
    var focused = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CallHistoryList.allCases, id: \.self) { list in
                let selected = selection == list.rawValue
                Button { selection = list.rawValue } label: {
                    Text(verbatim: list.localizedTabName)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.activeSegmentText : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            // Active tab like a native segmented control: filled with the accent color.
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.activeSegment)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)   // the control is one focus stop; ←/→ switch the tab
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.selectionRing, lineWidth: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityRepresentation {
            Picker(selection: $selection) {
                ForEach(CallHistoryList.allCases, id: \.self) { list in
                    Text(verbatim: list.localizedTabName).tag(list.rawValue)
                }
            } label: {
                Text("Recent Calls", comment: "VoiceOver label of the tabs above the recent calls in the popover.")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // As wide as the visible tabs: VoiceOver's cursor and hit area match what is on screen.
            .frame(maxWidth: .infinity)
        }
    }
}
