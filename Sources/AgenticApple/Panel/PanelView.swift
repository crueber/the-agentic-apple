import SwiftUI
import AgenticCore

enum PanelMetrics {
    static let width: CGFloat = 360
    static let hPad: CGFloat = 16
    static let coordinateSpace = "panelContent"
}

/// The open panel: hero, one section per agent (in the user's order), footer.
/// `scrollable` is false for previews (ImageRenderer can't draw a ScrollView).
struct PanelView: View {
    let state: DisplayState
    var actions = PanelActions()
    var scrollable = true
    var maxHeight: CGFloat = 640

    @State private var contentHeight: CGFloat = 200
    @State private var frames: [ProviderID: CGRect] = [:]
    @State private var drag: DragInfo?

    struct DragInfo: Equatable {
        var id: ProviderID
        var y: CGFloat
        var dropIndex: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHero(state: state, actions: actions)
                .padding(.horizontal, PanelMetrics.hPad)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider().padding(.horizontal, PanelMetrics.hPad - 4)
            if scrollable {
                ScrollView(.vertical) { content }
                    .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(contentHeight, maxHeight))
            } else {
                content
            }
            Divider().padding(.horizontal, PanelMetrics.hPad - 4)
            PanelFooter(state: state, actions: actions)
                .padding(.horizontal, PanelMetrics.hPad)
                .padding(.vertical, 8)
        }
        .frame(width: PanelMetrics.width)
    }

    // MARK: sections

    private var ids: [ProviderID] { state.panelProviders.map(\.id) }

    private var content: some View {
        VStack(spacing: 0) {
            let list = state.panelProviders
            if list.isEmpty {
                PanelEmptyState(state: state)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, provider in
                if index > 0 {
                    Divider().padding(.horizontal, PanelMetrics.hPad)
                }
                ProviderSection(provider: provider, state: state, actions: actions,
                                isDragged: drag?.id == provider.id,
                                grip: gripGesture(for: provider.id))
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: SectionFramesKey.self,
                                               value: [provider.id: geo.frame(in: .named(PanelMetrics.coordinateSpace))])
                    })
            }
        }
        .padding(.vertical, 2)
        .coordinateSpace(name: PanelMetrics.coordinateSpace)
        .overlay(alignment: .topLeading) { dragOverlay }
        .onPreferenceChange(SectionFramesKey.self) { frames = $0 }
        .background(GeometryReader { geo in
            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    // MARK: drag to reorder

    private func dropIndex(at y: CGFloat) -> Int {
        for (i, id) in ids.enumerated() {
            if let f = frames[id], y < f.midY { return i }
        }
        return ids.count
    }

    private func gripGesture(for id: ProviderID) -> AnyGesture<Void> {
        AnyGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(PanelMetrics.coordinateSpace))
                .onChanged { value in
                    let index = dropIndex(at: value.location.y)
                    if drag == nil {
                        drag = DragInfo(id: id, y: value.location.y, dropIndex: index)
                    } else {
                        drag?.y = value.location.y
                        if drag?.dropIndex != index {
                            withAnimation(.easeOut(duration: 0.12)) { drag?.dropIndex = index }
                        }
                    }
                }
                .onEnded { _ in
                    defer { drag = nil }
                    guard let d = drag, let from = ids.firstIndex(of: d.id) else { return }
                    var to = d.dropIndex
                    if to > from { to -= 1 }
                    if to != from {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { actions.reorder(d.id, to) }
                    }
                }
                .map { _ in () }
        )
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if let d = drag, let from = ids.firstIndex(of: d.id), let line = insertionY(d.dropIndex) {
            let noOp = d.dropIndex == from || d.dropIndex == from + 1
            ZStack(alignment: .topLeading) {
                if !noOp {
                    HStack(spacing: 0) {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 7, height: 7)
                        Rectangle().fill(Color.accentColor).frame(height: 2)
                    }
                    .frame(width: PanelMetrics.width - 2 * (PanelMetrics.hPad - 4))
                    .offset(x: PanelMetrics.hPad - 4, y: line - 3.5)
                }
                DragGhost(id: d.id)
                    .offset(x: PanelMetrics.hPad, y: max(0, d.y - 18))
            }
            .allowsHitTesting(false)
        }
    }

    private func insertionY(_ index: Int) -> CGFloat? {
        guard !ids.isEmpty else { return nil }
        if index >= ids.count { return frames[ids[ids.count - 1]]?.maxY }
        return frames[ids[max(0, index)]]?.minY
    }
}

private struct SectionFramesKey: PreferenceKey {
    static let defaultValue: [ProviderID: CGRect] = [:]
    static func reduce(value: inout [ProviderID: CGRect], nextValue: () -> [ProviderID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DragGhost: View {
    let id: ProviderID
    var body: some View {
        HStack(spacing: 8) {
            ProviderMark(id, size: 16)
            Text(id.displayName).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .frame(width: PanelMetrics.width - 2 * PanelMetrics.hPad, height: 36, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

// MARK: - Hero

struct PanelHero: View {
    let state: DisplayState
    let actions: PanelActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 11) {
            AgentMetersGlyph(size: 28)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(state.heroMeta)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            let top = state.heroPercent
            if !top.isEmpty {
                Text(top)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state.palette.color(state.heroPercentState, scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .help("Highest limit in the menu bar")
                    .accessibilityLabel(Text("Highest limit \(top)"))
            }
            HoverIconButton(systemName: "arrow.clockwise",
                            help: state.busy ? "Refreshing…" : "Refresh (R)",
                            spinning: state.busy, enabled: !state.busy, action: actions.refresh)
        }
    }
}

// MARK: - Footer

struct PanelFooter: View {
    let state: DisplayState
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 6) {
            Text(state.footerText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(state.footerText)
            Spacer(minLength: 4)
            HoverIconButton(systemName: "gearshape", help: "Settings…", action: actions.openSettings)
        }
    }
}

// MARK: - Empty state

struct PanelEmptyState: View {
    let state: DisplayState

    static let paths: [(ProviderID, String)] = [
        (.openrouter, "Set `OPENROUTER_API_KEY`, or sign in through OpenCode"),
        (.opencode, "`opencode auth login` to a workspace with a Go plan"),
        (.grok, "Run `grok` once and open `/usage`"),
        (.codex, "`codex login` with a ChatGPT plan"),
        (.claude, "`claude auth login`"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.busy || state.looking ? "Looking for agents" : "No agent found")
                    .font(.system(size: 13, weight: .semibold))
                Text(!state.lastError.isEmpty ? state.lastError
                     : "Sign in to any of these, and that agent appears here on the next refresh.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Self.paths, id: \.0) { id, how in
                    HStack(spacing: 10) {
                        ProviderMark(id, size: 14)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id.displayName).font(.system(size: 12, weight: .medium))
                            InlineCode.text(how, size: 11).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PanelMetrics.hPad)
        .padding(.vertical, 14)
    }
}
