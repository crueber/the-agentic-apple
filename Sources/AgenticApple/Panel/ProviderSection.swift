import SwiftUI
import AppKit
import AgenticCore

/// One agent: header (mark, name, tier · status, top %, show switch, grip),
/// hint, activity, a row per limit window, OpenRouter money, OpenCode budgets, error.
struct ProviderSection: View {
    let provider: Provider
    let state: DisplayState
    let actions: PanelActions
    var isDragged = false
    let grip: AnyGesture<Void>
    @Environment(\.colorScheme) private var scheme

    private var windows: [MeterWindow] { state.windows(provider) }
    private var allStale: Bool { !windows.isEmpty && windows.allSatisfy(\.stale) }

    private var summary: MeterWindow? { Meters.summaryWindow(windows) }

    private var subtitle: String {
        var parts: [String] = []
        if !provider.tier.isEmpty { parts.append(provider.tier) }
        if !provider.status.isEmpty { parts.append(provider.status) }
        if !state.isShown(provider.id) { parts.append("Hidden from bar") }
        return parts.joined(separator: " · ")
    }

    private var subtitleWarns: Bool { !provider.status.isEmpty && (windows.isEmpty || allStale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !provider.hint.isEmpty && (windows.isEmpty || allStale) {
                InlineCode.text(provider.hint, size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let activity = Summary.activityText(provider)
            if state.showActivity && !activity.isEmpty {
                Text(activity)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !windows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                        WindowRow(window: w, state: state)
                    }
                }
            }
            if let money = provider.money, !Summary.moneySummary(money).isEmpty {
                Text(Summary.moneySummary(money))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, windows.isEmpty ? 0 : -6)
            }
            if !provider.budgets.isEmpty { budgets }
            if !provider.error.isEmpty {
                Label {
                    InlineCode.text(provider.error, size: 11).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 11))
                .foregroundStyle(state.palette.color(.warning, scheme))
            }
        }
        .padding(.horizontal, PanelMetrics.hPad)
        .padding(.vertical, 12)
        .opacity(isDragged ? 0.35 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(provider.name))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderMark(provider.id, size: 20)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleWarns ? AnyShapeStyle(state.palette.color(.warning, scheme)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let s = summary, s.mode == .meter {
                Text(s.stale ? Format.dash : Format.percentText(s.percent))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state.palette.color(s.color, scheme))
                    .opacity(s.stale ? 0.55 : 1)
            }
            MiniSwitch(isOn: state.isShown(provider.id), label: "Show \(provider.name) in the menu bar") {
                actions.setShown(provider.id, $0)
            }
            GripHandle()
                .gesture(grip)
                .accessibilityLabel(Text("Reorder \(provider.name)"))
        }
    }

    private var budgets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Console budgets")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 2)
            ForEach(Array(provider.budgets.enumerated()), id: \.offset) { _, b in
                let st = Meters.stateOf(b.percent, warn: state.warn, critical: state.critical)
                let color = state.palette.color(st, scheme)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.label.isEmpty ? "Budget" : b.label).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Summary.budgetValueText(b))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                    }
                    MeterBar(percent: b.percent, color: color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(b.label) budget"))
                .accessibilityValue(Text(Summary.budgetValueText(b)))
            }
        }
    }
}

/// One limit window: label and value, meter, caption.
struct WindowRow: View {
    let window: MeterWindow
    let state: DisplayState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = state.palette.color(window.color, scheme)
        let caption = Summary.windowCaption(window, now: state.now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.detail)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Summary.windowValueText(window))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            if window.mode == .meter {
                MeterBar(percent: window.percent, color: color, dimmed: window.stale)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(window.over ? AnyShapeStyle(state.palette.color(.yellow, scheme)) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(window.stale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(window.detail))
        .accessibilityValue(Text([Summary.windowValueText(window), caption].filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

/// The ⠿ drag handle (six dots), with an open-hand cursor.
struct GripHandle: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to reorder")
    }
}
