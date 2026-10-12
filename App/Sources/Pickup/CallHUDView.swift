import SwiftUI

/// Floating call window: status/timer, optional audio controls, end call.
struct CallHUDView: View {
    let info: ActiveCallInfo
    let actions: CallActions
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let waiting = info.waiting {
                Text("Call waiting: \(waiting.primaryText ?? String(localized: "Unknown caller"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = info.notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Label("End Call", systemImage: "phone.down.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color.red, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("hud-hangup")
            }
        }
        .padding(16)
        .frame(width: 320)
        .callSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call-hud")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch info.phase {
        case .dialing:
            Text("Calling…").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
        case .ringing:
            Text("Ringing…").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
        case .active:
            if let start = info.startedAt {
                // Re-evaluated once a second. The text and the accessibility value are the same elapsed time;
                // `.updatesFrequently` tells VoiceOver not to announce every tick (it reads the value on focus).
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    Text(verbatim: CallDurationFormat.string(elapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Call duration"))
                        .accessibilityValue(Text(verbatim: CallDurationFormat.spoken(elapsed)))
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("hud-timer")
                }
            }
        case .held:
            Text("On hold").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
        case .ended:
            if let text = info.endText {
                Text(verbatim: text).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("hud-state")
            }
            if let duration = info.endDuration {
                Text(verbatim: duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(party: info.party, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text("Call with \(title)"))
                    .accessibilityIdentifier("hud-caller")
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
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
