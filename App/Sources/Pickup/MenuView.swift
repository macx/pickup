import AppKit
import PickupCore
import SwiftUI

/// Content of the menu bar popover: [content area] + bottom bar (status left, round glass menu right).
struct MenuView: View {
    let model: AppModel
    let openSettings: () -> Void
    let showAbout: () -> Void
    let close: () -> Void
    @AppStorage(PopoverWidth.defaultsKey) private var savedWidth = Double(PopoverWidth.minimum)
    /// Width while an edge is being dragged; saved when the drag ends.
    @State private var liveWidth: CGFloat?

    private var width: CGFloat { liveWidth ?? PopoverWidth.clamped(savedWidth) }

    var body: some View {
        // Structure for step B: [top bar: grid button + search capsule] / [collapsible content: keypad or
        // results] / [bottom bar]. The three parts are separate stack children so the top bar and the
        // folding keypad can be added without reworking the bottom bar or the guidance area.
        VStack(spacing: 0) {
            DialerView(model: model, contentWidth: width - 2 * DialerView.sideMargin, openSettings: openSettings, close: close)

            BottomBar(status: model.connection, openSettings: openSettings, showAbout: showAbout)
        }
        .frame(width: width)
        .overlay(alignment: .leading) { resizeEdge(.leading) }
        .overlay(alignment: .trailing) { resizeEdge(.trailing) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover-root")
        .onAppear { Task { await model.permissions.refresh() } }
    }
}

extension MenuView {
    private func resizeEdge(_ edge: HorizontalEdge) -> some View {
        PopoverResizeEdge(edge: edge, width: width) { live in
            liveWidth = live
        } commit: { final in
            liveWidth = nil
            savedWidth = Double(final)
        }
    }
}

/// An invisible strip along a side edge of the popover: dragging it changes the popover's width (the
/// keypad keeps its size; search and lists grow). VoiceOver adjusts it with increment/decrement.
private struct PopoverResizeEdge: View {
    let edge: HorizontalEdge
    let width: CGFloat
    let live: (CGFloat) -> Void
    let commit: (CGFloat) -> Void
    /// Pointer x (screen coordinates) and width when the drag began. Screen coordinates, because the
    /// popover moves under the pointer while it grows.
    @State private var start: (x: CGFloat, width: CGFloat)?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let x = NSEvent.mouseLocation.x
                        if start == nil {
                            start = (x, width)
                            NotificationCenter.default.post(name: .pickupPopoverResizing, object: true)
                        }
                        guard let origin = start else { return }
                        live(PopoverWidth.resized(from: origin.width, outwardDelta: (x - origin.x) * (edge == .trailing ? 1 : -1)))
                    }
                    .onEnded { _ in
                        start = nil
                        commit(width)
                        NotificationCenter.default.post(name: .pickupPopoverResizing, object: false)
                    })
            .accessibilityElement()
            .accessibilityLabel(Text("Window width", comment: "VoiceOver label of the invisible handle at the side of the popover that changes its width."))
            .accessibilityValue(Text(verbatim: "\(Int(width))"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(PopoverWidth.clamped(width + PopoverWidth.accessibilityStep))
                case .decrement: commit(PopoverWidth.clamped(width - PopoverWidth.accessibilityStep))
                @unknown default: break
                }
            }
            .accessibilityHidden(edge == .leading)   // one handle is enough for VoiceOver
    }
}

/// Status on the left, one round Liquid Glass button with the app menu on the right.
private struct BottomBar: View {
    let status: ConnectionStatus
    let openSettings: () -> Void
    let showAbout: () -> Void
    @State private var anchor = AnchorView.Holder()

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            GlassEffectContainer {
                Button {
                    AppMenu.pop(from: anchor.view, openSettings: openSettings, showAbout: showAbout)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .accessibilityLabel(Text("More", comment: "VoiceOver label of the round menu button in the popover."))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .background(AnchorView(holder: anchor))
                .help(Text("More", comment: "Tooltip of the round menu button in the popover."))
                .accessibilityIdentifier("more-button")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .connecting, .reconnecting: .secondary
        case .noPhone, .disconnected: .orange
        }
    }

    private var text: String {
        switch status {
        case .noPhone:
            String(localized: "No phone selected", comment: "Menu status line when no phone has been chosen in Settings.")
        case .connected(let name):
            String(localized: "Connected to \(name)", comment: "Menu status line. %@ is the phone name, e.g. \"Pixel 9 Pro\".")
        case .connecting(let name):
            String(localized: "Connecting to \(name)…", comment: "Menu status line while the Bluetooth link is being set up. %@ is the phone name.")
        case .reconnecting(let name):
            String(localized: "Reconnecting to \(name)…", comment: "Menu status line while Pickup retries the Bluetooth link after it dropped. %@ is the phone name.")
        case .disconnected(let name):
            String(localized: "Not connected to \(name)", comment: "Menu status line when the Bluetooth link is down. %@ is the phone name.")
        }
    }
}

/// Short first-run / problem hint with one action, in the style of a system callout.
struct GuidanceCard: View {
    let guidance: AppModel.Guidance
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: action) { Text(verbatim: buttonTitle) }
                if guidance == .makeDefaultForLinks {
                    Button("Not Now") { model.linkHandler.dismissHint() }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch guidance {
        case .choosePhone:
            String(localized: "Choose your phone", comment: "First-run guidance title: no phone selected yet.")
        case .bluetoothDenied:
            String(localized: "Bluetooth access is off", comment: "Guidance title: the user denied Bluetooth access to Pickup.")
        case .cannotConnect(let name?):
            String(localized: "Can’t reach \(name)", comment: "Guidance title when the Bluetooth link does not come up. %@ is the phone name.")
        case .makeDefaultForLinks:
            String(localized: "Use Pickup for phone links", comment: "First-run hint title: another app still opens tel: links.")
        case .cannotConnect(nil):
            String(localized: "Can’t reach your phone", comment: "Guidance title when the Bluetooth link does not come up and the phone's name is unknown. Separate from the named variant because the name slot needs no inflection here.")
        }
    }

    private var message: String {
        switch guidance {
        case .choosePhone:
            String(localized: "Pair your phone in System Settings > Bluetooth, then select it in Pickup’s settings.",
                   comment: "First-run guidance text.")
        case .bluetoothDenied:
            String(localized: "Allow Pickup under Privacy & Security > Bluetooth so it can talk to your phone.",
                   comment: "Guidance text when Bluetooth access was denied.")
        case .makeDefaultForLinks:
            String(localized: "Phone number links in Safari and other apps still open another app. Make Pickup the default to place those calls on your phone.",
                   comment: "First-run hint text about tel: links.")
        case .cannotConnect:
            String(localized: "Make sure Bluetooth is on and the phone is nearby. If the phone asks, allow this Mac to access phone calls (Pixel: Bluetooth settings, “Phone calls”).",
                   comment: "Guidance text when the Bluetooth link does not come up. Mentions the Android permission \"Phone calls\" in the paired-device settings.")
        }
    }

    private var buttonTitle: String {
        switch guidance {
        case .choosePhone:
            String(localized: "Choose Phone…", comment: "Button that opens Pickup’s settings to select the phone.")
        case .bluetoothDenied:
            String(localized: "Open Privacy Settings…", comment: "Button that opens the Bluetooth privacy pane in System Settings.")
        case .makeDefaultForLinks:
            String(localized: "Make Default", comment: "Button that makes Pickup the default app for phone links. Keep it short.")
        case .cannotConnect:
            String(localized: "Try Again", comment: "Button that retries the Bluetooth connection.")
        }
    }

    private func action() {
        switch guidance {
        case .choosePhone: openSettings()
        case .bluetoothDenied: PermissionsModel.openBluetoothPrivacySettings()
        case .cannotConnect: model.reconnect()
        case .makeDefaultForLinks: Task { await model.linkHandler.makeDefault() }
        }
    }
}
