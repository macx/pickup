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

/// Keyboard hint shown under the buttons while a call panel has keyboard focus. The visible text uses
/// the key symbols (↩ ⎋); VoiceOver reads the spelled-out sentence instead.
struct KeyboardHint: View {
    let text: LocalizedStringKey
    let spoken: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(spoken))
            .accessibilityIdentifier("keyboard-hint")
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
                    .font(.caption)
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
        case .accept: AnyShapeStyle(Color.green)
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
