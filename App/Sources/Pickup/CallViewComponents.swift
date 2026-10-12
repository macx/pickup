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
