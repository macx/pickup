import SwiftUI

/// Incoming-call banner in the style of Continuity call notifications.
struct IncomingCallBannerView: View {
    let info: IncomingCallInfo
    let actions: CallActions
    var hasFocus = false

    private var title: String { info.party.primaryText ?? String(localized: "Unknown caller") }

    var body: some View {
        VStack(spacing: 8) {
            content
            if hasFocus {
                KeyboardHint(text: "Press Return to accept or Esc to decline.")
            }
        }
        .padding(14)
        .frame(width: 420)
        .callSurface(hasFocus: hasFocus)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incoming-banner")
    }

    private var content: some View {
        HStack(spacing: 12) {
            AvatarView(party: info.party, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = info.party.secondaryText {
                    Text(verbatim: secondary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("Incoming call on \(info.phoneName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = info.notice {
                    Text(verbatim: notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Incoming call from \(title)"))
            .accessibilityIdentifier("banner-caller")

            HStack(spacing: 6) {
                CircleControl(symbol: "phone.down.fill", title: "Decline", style: .destructive,
                              accessibilityLabel: "Decline call", identifier: "banner-decline", action: actions.decline)
                    .keyboardShortcut(.cancelAction)
                CircleControl(symbol: "phone.fill", title: "Accept", style: .accept,
                              accessibilityLabel: "Accept call", identifier: "banner-accept", action: actions.accept)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

#Preview("Incoming") {
    IncomingCallBannerView(
        info: IncomingCallInfo(party: CallParty(displayName: "Anna Schmidt", number: "+49 170 1234567"),
                               phoneName: "Pixel 9 Pro"),
        actions: CallActions())
}
