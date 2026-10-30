import AppKit
import PickupCore
import SwiftUI

/// Placeholder rows while the recent calls are read for the first time (like PrimeNG's Skeleton):
/// avatar, name and detail bars and the call button's circle, with a light sweeping across. Static
/// with Reduce Motion. VoiceOver hears one "Loading recent calls" element.
struct RecentCallsSkeleton: View {
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
struct ShimmerBand: View {
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

/// Tabs above the recent calls: equal segments that always fill the given width exactly. The native
/// segmented control sizes itself from its labels and grew wider than the popover with the German
/// texts, which shifted the whole content. VoiceOver still gets a real segmented picker.
struct RecentCallsTabs: View {
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
