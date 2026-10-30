import SwiftUI

/// Floating call window: status/timer, optional audio controls, end call.
struct CallHUDView: View {
    let info: ActiveCallInfo
    let actions: CallActions
    var hasFocus = false
    @State private var showKeypad = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { info.party.primaryText ?? String(localized: "Unknown caller") }

    var body: some View {
        VStack(spacing: 16) {
            header
            if showKeypad && info.audioOnMac && info.phase == .active {
                KeypadView(onDigit: actions.sendDigit)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
            }
            if info.audioOnMac && info.phase != .ended {
                HStack(alignment: .top, spacing: 10) {
                    CircleControl(symbol: info.isMuted ? "mic.slash.fill" : "mic.fill",
                                  title: "Mute", style: info.isMuted ? .toggled : .neutral,
                                  accessibilityLabel: info.isMuted ? "Unmute" : "Mute",
                                  identifier: "hud-mute", action: actions.toggleMute)
                    CircleControl(symbol: "circle.grid.3x3.fill", title: "Keypad",
                                  style: showKeypad ? .toggled : .neutral,
                                  accessibilityLabel: showKeypad ? "Hide Keypad" : "Keypad",
                                  identifier: "hud-keypad") {
                        withAnimation(reduceMotion ? nil : .snappy) { showKeypad.toggle() }
                    }
                    CircleControl(symbol: "iphone.and.arrow.forward", title: "Move to Phone",
                                  accessibilityLabel: "Move call to phone", identifier: "hud-move-to-phone", action: actions.moveToPhone)
                }
            } else if info.phase != .ended {
                Text("Call audio is on \(info.phoneName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsHoldControl {
                CircleControl(symbol: info.phase == .held ? "play.fill" : "pause.fill",
                              title: info.phase == .held ? "Resume" : "Hold",
                              style: info.phase == .held ? .toggled : .neutral,
                              identifier: "hud-hold", action: actions.toggleHold)
            }
            if let held = info.held, info.phase == .active {
                heldCallRow(held)
            }
            if let waiting = info.waiting {
                if info.canHold {
                    waitingCallCard(waiting)
                } else {
                    Text("Call waiting: \(waiting.primaryText ?? String(localized: "Unknown caller"))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notice = info.notice {
                StatusMessage(text: notice)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if info.phase == .ended {
                Button(action: actions.dismiss) {
                    Text("Close")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(.gray.opacity(0.3), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hud-close")
            } else {
                Button(action: actions.endCall) {
                    Group {
                        if info.isEnding {
                            // The phone confirms the hang-up after a second or two; until then the button
                            // shows progress instead of looking unresponsive.
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
                                Text("Ending…")
                            }
                        } else {
                            Label("End Call", systemImage: "phone.down.fill")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color.red.opacity(info.isEnding ? 0.7 : 1), in: Capsule())
                    .contentShape(Capsule())
                    .contentShape(.focusEffect, Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(info.isEnding)
                // The HUD is key only after the user focused it (menu bar icon, global shortcut or a click
                // on the HUD); then Return ends the call. Esc does nothing here.
                .callPanelDefaultButton(panelHasFocus: hasFocus, action: actions.endCall)
                .accessibilityIdentifier("hud-hangup")
            }
        }
        .padding(16)
        .frame(width: 320)
        .callSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call-hud")
    }

    /// Hold / Resume for a single call (with two calls, the second call's row offers Swap instead).
    private var showsHoldControl: Bool {
        info.canHold && info.held == nil && info.waiting == nil && (info.phase == .active || info.phase == .held)
    }

    /// The call on hold while another one is active: swap to it or end it.
    private func heldCallRow(_ held: CallParty) -> some View {
        let name = held.primaryText ?? String(localized: "Unknown caller")
        return SecondCallRow(party: held, status: String(localized: "On hold")) {
            Button(action: actions.swapCalls) {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Swap to \(name)", comment: "VoiceOver label of the button that swaps to the call on hold. %@ is the caller's name or number."))
            .help(Text("Swap to \(name)"))
            .accessibilityIdentifier("hud-swap")
            Button(action: actions.endHeld) {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.red, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text("End call with \(name)", comment: "VoiceOver label of the button that ends the call on hold. %@ is the caller's name or number."))
            .help(Text("End call with \(name)"))
            .accessibilityIdentifier("hud-end-held")
        }
    }

    /// A second caller: take the call (holding or ending the current one) or decline it.
    private func waitingCallCard(_ waiting: CallParty) -> some View {
        let holdAndAccept = Button(action: actions.acceptWaitingHolding) {
            Text("Hold & Accept", comment: "Button in the call window when a second call comes in: puts the current call on hold and answers the new one.")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.callGreen)
        .accessibilityIdentifier("hud-waiting-hold-accept")
        let endAndAccept = Button(action: actions.acceptWaitingEnding) {
            Text("End & Accept", comment: "Button in the call window when a second call comes in: ends the current call and answers the new one.")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("hud-waiting-end-accept")
        let decline = Button(action: actions.rejectWaiting) {
            Text("Decline").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityIdentifier("hud-waiting-decline")
        return VStack(spacing: 8) {
            SecondCallRow(party: waiting, status: String(localized: "Call waiting", comment: "Status of a second incoming call in the call window (call waiting).")) {}
            if info.held == nil { holdAndAccept }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { endAndAccept; decline }
                VStack(spacing: 8) { endAndAccept; decline }
            }
        }
        .controlSize(.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud-waiting")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch info.phase {
        case .dialing:
            Text("Calling…").font(.body).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
        case .ringing:
            Text("Ringing…").font(.body).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
        case .active:
            if let start = info.startedAt {
                // Re-evaluated once a second. The text and the accessibility value are the same elapsed time;
                // `.updatesFrequently` tells VoiceOver not to announce every tick (it reads the value on focus).
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    Text(verbatim: CallDurationFormat.string(elapsed))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Call duration"))
                        .accessibilityValue(Text(verbatim: CallDurationFormat.spoken(elapsed)))
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("hud-timer")
                }
            }
        case .held:
            Text("On hold").font(.body).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
        case .ended:
            if let text = info.endText {
                Text(verbatim: text).font(.body).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
            }
            if let duration = info.endDuration {
                Text(verbatim: duration).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(party: info.party, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Call with \(title)"))
                    .accessibilityIdentifier("hud-caller")
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A second call (held or waiting) under the main call: avatar, name, status and its buttons.
private struct SecondCallRow<Actions: View>: View {
    let party: CallParty
    let status: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(party: party, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: party.primaryText ?? String(localized: "Unknown caller"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            actions()
        }
        .padding(8)
        .background(.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct KeypadView: View {
    let onDigit: (Character) -> Void
    /// The HUD keypad takes keyboard focus for typing digits; the dial pad leaves it to its text field.
    var focusable = true

    private static let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(Array(Self.keys.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.0) { key in
                        Button { onDigit(Character(key.0)) } label: {
                            VStack(spacing: 0) {
                                Text(verbatim: key.0).font(.title2.weight(.medium))
                                Text(verbatim: key.1).font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(height: 10)
                            }
                            .frame(width: 58, height: 50)
                            .background(.gray.opacity(0.3), in: Circle().inset(by: -2))
                            .contentShape(Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(Text(verbatim: key.0))
                    }
                }
            }
        }
        .focusable(focusable)
        .onKeyPress(characters: CharacterSet(charactersIn: "0123456789*#")) { press in
            guard focusable, let c = press.characters.first else { return .ignored }
            onDigit(c)
            return .handled
        }
    }
}

#Preview("Call – audio on Mac") {
    CallHUDView(info: ActiveCallInfo(party: CallParty(displayName: "Anna Schmidt", number: "+49 170 1234567"),
                                     phase: .active, startedAt: .now, phoneName: "Pixel 9 Pro",
                                     audioOnMac: true, isMuted: false), actions: CallActions())
}

#Preview("Call – remote control") {
    CallHUDView(info: ActiveCallInfo(party: CallParty(displayName: nil, number: "+49 170 1234567"),
                                     phase: .dialing, startedAt: nil, phoneName: "Pixel 9 Pro",
                                     audioOnMac: false, isMuted: false), actions: CallActions())
}
