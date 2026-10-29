import AppKit
import SwiftUI

/// Rounded material surface shared by banner and HUD (matches system notification banners).
struct CallSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5))
            .padding(12) // room for the window shadow
    }
}

extension View {
    func callSurface() -> some View { modifier(CallSurface()) }
}

/// Makes a call panel's primary button behave like the default button of a macOS dialog: while the
/// panel is the key window the button has keyboard focus (the system draws the focus ring) and Return
/// presses it. Without focus nothing reacts to the keyboard.
///
/// In the borderless call panels a focused button swallows Return and Esc before any
/// `.keyboardShortcut` sees them, so Return is handled here with `onKeyPress` (Space presses the
/// focused button as usual). Esc, where a panel uses it, needs `onKeyPress` on the panel as well.
private struct CallPanelDefaultButton: ViewModifier {
    let panelHasFocus: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .onKeyPress(.return) {
                action()
                return .handled
            }
            .onAppear { focused = panelHasFocus }
            .onChange(of: panelHasFocus) { _, hasFocus in focused = hasFocus }
    }
}

extension View {
    func callPanelDefaultButton(panelHasFocus: Bool, action: @escaping () -> Void) -> some View {
        modifier(CallPanelDefaultButton(panelHasFocus: panelHasFocus, action: action))
    }
}

extension Color {
    /// Darker green and orange (Apple's increased-contrast variants of the system colors), so white
    /// symbols on them reach at least 3:1 (WCAG 1.4.11); the regular system green and orange give about 2:1.
    static let callGreen = Color(red: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255)
    static let warningOrange = Color(red: 0xC9 / 255, green: 0x34 / 255, blue: 0x00 / 255)

    // Dialer list colors, light and dark. Measured against popover backgrounds from #E4E4E4 to white
    // (light) and #1E1E1E to #363636 (dark), also on the selection fill: text reaches 4.5:1 (WCAG
    // 1.4.3), the selection ring 3:1 (1.4.11). The system red and secondary label stay below that.

    /// Title of a missed call.
    static let missedRed = adaptive(light: 0xA8221A, dark: 0xFFA39C)
    /// Second line of a result or recent call row.
    static let rowSubtitle = adaptive(light: 0x56565B, dark: 0xB4B4B9)
    /// Outline of the selected row: the state is visible without relying on the faint fill.
    static let selectionRing = adaptive(light: 0x0064E1, dark: 0x4DA3FF)
    static let selectionFill = adaptive(light: 0x0064E1, dark: 0x4DA3FF, alpha: 0.15)
    /// Active recent calls tab: the system's selection color, derived from the user's accent color
    /// (darker than the accent itself, so the white label reaches 4.5:1), with its label color.
    static let activeSegment = Color(nsColor: .selectedContentBackgroundColor)
    static let activeSegmentText = Color(nsColor: .alternateSelectedControlTextColor)

    static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}

/// A warning or error line. The symbol carries the meaning; the text stays in the primary label color,
/// because orange or red text on a light background stays below the 4.5:1 contrast for text.
struct StatusMessage: View {
    enum Kind { case warning, error }

    let text: String
    var kind: Kind = .warning
    var font: Font = .callout

    var body: some View {
        Label {
            Text(verbatim: text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            switch kind {
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            case .error:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .font(font)
    }
}

struct AvatarView: View {
    let party: CallParty
    var size: CGFloat

    var body: some View {
        Group {
            if let data = party.avatarPNG, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let initials = party.initials {
                ZStack {
                    Circle().fill(.gray.gradient)
                    Text(verbatim: initials)
                        .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Circle().fill(.gray.gradient)
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Round button with a caption below, like the Continuity call controls.
struct CircleControl: View {
    enum Style { case neutral, toggled, accept, destructive }

    let symbol: String
    let title: LocalizedStringKey
    var style: Style = .neutral
    var diameter: CGFloat = 44
    var accessibilityLabel: LocalizedStringKey? = nil
    /// Stable identifier for UI tests (not user-visible).
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .frame(width: diameter, height: diameter)
                    .foregroundStyle(foreground)
                    .background(background, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 64)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var foreground: Color { style == .toggled ? .black : .white }
    private var background: AnyShapeStyle {
        switch style {
        case .neutral: AnyShapeStyle(.gray.opacity(0.55))
        case .toggled: AnyShapeStyle(.white)
        case .accept: AnyShapeStyle(Color.callGreen)
        case .destructive: AnyShapeStyle(Color.red)
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
