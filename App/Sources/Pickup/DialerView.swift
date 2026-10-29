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
    @FocusState private var fieldFocused: Bool
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
                        keypad.transition(.opacity)
                    }
                    if queryIsEmpty && !showKeypad {
                        recentCalls.transition(.opacity)
                    }
                }
                .frame(height: Self.keypadHeight, alignment: .top)
            }
            if !queryIsEmpty {
                content
            }
            if let error {
                StatusMessage(text: error, kind: .error)
            }
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
        .onAppear {
            focusFieldSoon()
            DialerKeyRouter.shared.move = { delta in moveSelection(delta) }
            DialerKeyRouter.shared.escape = { handleEscape() }
            DialerKeyRouter.shared.tab = { backwards in handleTab(backwards: backwards) }
            DialerKeyRouter.shared.switchTab = { delta in
                guard let index = CallHistoryList.allCases.firstIndex(of: recentList) else { return false }
                return selectTab(index + delta)
            }
            DialerKeyRouter.shared.selectTab = { index in selectTab(index) }
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
        .onChange(of: fieldFocused) { _, focused in
            if focused {
                collapseCaret()
            } else if queryIsEmpty {
                selectedID = nil   // Return goes to the focused control now, not to a recent call
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
            fieldFocused = true
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

    /// Esc: leave the recent calls list first, then clear the field; with an empty field the popover
    /// closes (return false).
    private func handleEscape() -> Bool {
        if queryIsEmpty, selectedID != nil {
            leaveList()
            return true
        }
        guard !text.isEmpty else { return false }
        text = ""
        keypadText = ""
        return true
    }

    /// Tab moves from the field into the list (selects the first row), Shift-Tab back to the field.
    /// Typing still goes to the field; Return calls the selected row.
    ///
    /// A second Tab keeps its system meaning (with Full Keyboard Access it moves on to the tabs and
    /// buttons), so the list is never a keyboard trap; leaving the field clears the list selection.
    private func handleTab(backwards: Bool) -> Bool {
        let rows = self.rows
        let inList = rows.contains { $0.id == selectedID }
        if backwards {
            guard inList, queryIsEmpty else { return false }
            leaveList()
            announce(String(localized: "Search field", comment: "VoiceOver announcement when the keyboard leaves the recent calls list and returns to the popover's search field."))
            return true
        }
        guard !rows.isEmpty, !inList else { return false }
        selectedID = rows[0].id
        announceSelection(rows[0])
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

    /// The text field keeps keyboard focus while rows are selected, so VoiceOver is told explicitly.
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
        fieldFocused = true
        collapseCaret()
    }

    // MARK: Top bar

    private var topBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: toggleKeypad) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showKeypad ? Color.white : Color.primary)
                        .frame(width: 34, height: 34)
                        .glassEffect(showKeypad ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                     in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
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
                        .focused($fieldFocused)
                        .onSubmit(submitFromReturn)
                        .accessibilityIdentifier("search-field")
                        .accessibilityLabel(Text("Search contacts or enter a number", comment: "VoiceOver label of the popover's search field."))
                    if !text.isEmpty {
                        Button { text = ""; keypadText = ""; fieldFocused = true } label: {
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
        fieldFocused = true
    }

    // MARK: Keypad

    /// Height of the keypad (five rows of 60 pt keys, 12 pt apart); the recent calls take the same.
    static let keypadHeight: CGFloat = 5 * 60 + 4 * 12
    static let callButtonSize: CGFloat = 28

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
            .frame(width: 60, height: 60)
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay(Circle().fill(Color.primary.opacity(pressed ? 0.22 : 0)))
            .scaleEffect(pressed ? 0.93 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                ForEach(Self.keys, id: \.self) { row in
                    HStack(spacing: 16) {
                        ForEach(row, id: \.self) { key in
                            keypadKey(key)
                        }
                    }
                }
                Button(action: placeTypedCall) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .glassEffect(.regular.tint(.callGreen).interactive(), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
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
                        .disabled(!model.canDial)
                        .id(row.id)
                        .accessibilityIdentifier(row.testIdentifier)
                        // Single click selects; double-click or Return calls (a stray click never dials).
                        .simultaneousGesture(TapGesture(count: 2).onEnded { activate(row) })
                        .accessibilityAction(.default) { activate(row) }
                        .accessibilityHint(Text("Double-click or press Return to call.", comment: "VoiceOver hint of a search result row in the popover."))
                        .overlay(alignment: .trailing) {
                            if row.isRecent { recentCallButton(row) }
                        }
                    }
                }
            }
            .frame(maxHeight: fill ? .infinity : (showKeypad ? 3 : 6) * 50, alignment: .top)
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
        .disabled(!dialable)
        .opacity(dialable ? 1 : 0.35)
        .padding(.trailing, 2)   // circle 8 pt from the row's edge, like the avatar on the left
        .accessibilityLabel(Text(verbatim: label))
        .help(Text(verbatim: label))
        .accessibilityIdentifier(row.testIdentifier + "-call")
    }

    // MARK: Recent calls

    private var recentCalls: some View {
        let history = model.callHistory
        let rows = self.rows
        return VStack(spacing: 8) {
            Picker(selection: $recentListRaw) {
                ForEach(CallHistoryList.allCases, id: \.self) { list in
                    Text(verbatim: list.localizedTabName).tag(list.rawValue)
                }
            } label: {
                Text("Recent Calls", comment: "VoiceOver label of the tabs above the recent calls in the popover.")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("recent-tabs")
            .accessibilityHint(Text("Use the left and right arrow keys or Command-1 to 3 to switch tabs.", comment: "VoiceOver hint of the recent calls tabs in the popover."))

            if rows.isEmpty {
                // Rows stay cached while the phone is asked again; the spinner only shows before the first answer.
                Group {
                    if history.isLoading {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(Text("Loading recent calls", comment: "VoiceOver label of the progress indicator while the recent calls are read from the phone."))
                    } else {
                        Text("No calls", comment: "Empty state of a recent calls tab in the popover.")
                            .font(.callout).foregroundStyle(Color.rowSubtitle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultList(rows, fill: true)
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
        fieldFocused = true
        collapseCaret()
    }

    private func moveSelection(_ delta: Int) -> Bool {
        let rows = self.rows
        guard !rows.isEmpty else { return false }
        let index = min(max(selectedIndex + delta, 0), rows.count - 1)
        if selectedID != rows[index].id { announceSelection(rows[index]) }
        selectedID = rows[index].id
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
            fieldFocused = true
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
    /// Tab (false) or Shift-Tab (true); returns true when the dialer used the key.
    var tab: ((Bool) -> Bool)?
    /// Left/right arrow: previous/next recent calls tab (only while the field is empty).
    var switchTab: ((Int) -> Bool)?
    /// ⌘1 to ⌘3: recent calls tab by position.
    var selectTab: ((Int) -> Bool)?
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
