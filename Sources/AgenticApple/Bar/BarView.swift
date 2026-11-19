import SwiftUI
import AgenticCore

/// Metrics for the status item content. Tight on purpose: notched displays
/// leave little room right of the notch.
enum BarMetrics {
    static let height: CGFloat = 22
    static let markSize: CGFloat = 15
    static let meterWidth: CGFloat = 15
    static let meterHeight: CGFloat = 3
    static let meterSpacing: CGFloat = 2
    static let chipInnerSpacing: CGFloat = 3.5
    static let chipSpacing: CGFloat = 9
    static let horizontalPadding: CGFloat = 1
}

/// The status item's content: per shown agent, its mark and up to three tiny
/// stacked meters (or short percentages / marks only), in the user's order.
struct BarView: View {
    let state: DisplayState

    var body: some View {
        HStack(spacing: BarMetrics.chipSpacing) {
            let shown = state.barProviders
            if shown.isEmpty {
                AgentMetersGlyph(size: BarMetrics.markSize + 1)
                    .opacity(state.panelProviders.isEmpty ? 0.75 : 0.55)
                    .accessibilityLabel(Text(state.panelProviders.isEmpty ? "No AI agents found" : "All agents hidden"))
            } else {
                ForEach(shown) { provider in
                    BarChip(provider: provider, state: state)
                }
            }
        }
        .padding(.horizontal, BarMetrics.horizontalPadding)
        .frame(height: BarMetrics.height)
        .foregroundStyle(.primary)
        .fixedSize()
    }
}

struct BarChip: View {
    let provider: Provider
    let state: DisplayState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: BarMetrics.chipInnerSpacing) {
            ProviderMark(provider.id, size: BarMetrics.markSize)
            switch state.barStyle {
            case .bars:
                let meters = Meters.barMeters(provider, history: state.history, warn: state.warn, critical: state.critical)
                if !meters.isEmpty {
                    VStack(spacing: BarMetrics.meterSpacing) {
                        ForEach(Array(meters.enumerated()), id: \.offset) { _, w in
                            BarMeter(window: w, palette: state.palette)
                        }
                    }
                }
                let dollars = Meters.barDollarsText(provider, history: state.history, warn: state.warn, critical: state.critical)
                if !dollars.isEmpty {
                    let color = Meters.barDollarsColor(provider, history: state.history, warn: state.warn, critical: state.critical)
                    Text(dollars)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(state.palette.color(color, scheme))
                }
            case .text where Meters.isAccountWide(provider):
                // Account-wide OpenRouter: the credits figure only, as in the meters style.
                Text(Meters.barDollarsText(provider, history: state.history, warn: state.warn, critical: state.critical))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            case .text:
                Text(Summary.compactText(provider, history: state.history, warn: state.warn, critical: state.critical))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(state.palette.color(Meters.providerColor(provider, history: state.history,
                                                                                 warn: state.warn, critical: state.critical), scheme))
                    .lineLimit(1)
            case .icon:
                EmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(provider.name))
        .accessibilityValue(Text(Summary.compactText(provider, history: state.history, warn: state.warn, critical: state.critical)))
    }
}

/// One tiny horizontal meter: a thin rounded track and a fill in the window's colour.
struct BarMeter: View {
    let window: MeterWindow
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fraction = min(1, max(0, window.percent / 100))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.28 : 0.22))
            Capsule()
                .fill(window.color == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(palette.color(window.color, scheme)))
                .frame(width: max(BarMetrics.meterHeight, BarMetrics.meterWidth * fraction))
                .opacity(window.stale ? 0.45 : 1)
        }
        .frame(width: BarMetrics.meterWidth, height: BarMetrics.meterHeight)
        .animation(.easeOut(duration: 0.25), value: window.percent)
        .accessibilityElement()
        .accessibilityLabel(Text(window.detail))
        .accessibilityValue(Text(Summary.windowValueText(window)))
    }
}
