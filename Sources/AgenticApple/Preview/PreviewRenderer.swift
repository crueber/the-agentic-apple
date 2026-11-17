import AppKit
import SwiftUI
import AgenticCore

/// `--render-preview <dir>`: PNGs of the menu bar item and the open panel, light
/// and dark, @2x, from the synthetic fixture. Used for the README and website.
@MainActor
enum PreviewRenderer {
    static func render(to dir: URL, scale: CGFloat = 2) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [URL] = []
        let state = PreviewFixture.state
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let jobs: [(String, AnyView)] = [
                ("bar-\(suffix).png", AnyView(MenuBarMock(state: state, scheme: scheme))),
                ("panel-\(suffix).png", AnyView(PanelCard(state: state, scheme: scheme).padding(24).background(Backdrop(scheme: scheme)))),
                ("preview-\(suffix).png", AnyView(Composite(state: state, scheme: scheme))),
            ]
            for (name, view) in jobs {
                let url = dir.appendingPathComponent(name)
                try png(view.environment(\.colorScheme, scheme), scale: scale, scheme: scheme).write(to: url)
                written.append(url)
            }
            // Extra states, handy for checking the design.
            var empty = DisplayState()
            empty.now = PreviewFixture.now
            let extra: [(String, AnyView)] = [
                ("panel-empty-\(suffix).png", AnyView(PanelCard(state: empty, scheme: scheme).padding(24).background(Backdrop(scheme: scheme)))),
                ("bar-styles-\(suffix).png", AnyView(BarStyles(state: state, scheme: scheme))),
                ("panel-states-\(suffix).png", AnyView(PanelCard(state: PreviewFixture.edgeState, scheme: scheme).padding(24).background(Backdrop(scheme: scheme)))),
            ]
            for (name, view) in extra {
                let url = dir.appendingPathComponent(name)
                try png(view.environment(\.colorScheme, scheme), scale: scale, scheme: scheme).write(to: url)
                written.append(url)
            }
        }
        return written
    }

    static func png<V: View>(_ view: V, scale: CGFloat, scheme: ColorScheme) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: CGImage?
        appearance?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        guard let cg = image ?? renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

// MARK: - Mock surfaces

/// A wallpaper-ish backdrop behind the mock menu bar and panel.
private struct Backdrop: View {
    let scheme: ColorScheme
    var body: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.17, green: 0.13, blue: 0.20)]
                       : [Color(red: 0.80, green: 0.86, blue: 0.94), Color(red: 0.93, green: 0.88, blue: 0.90)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The panel as it appears in its popover: rounded, bordered, shadowed card.
struct PanelCard: View {
    let state: DisplayState
    let scheme: ColorScheme
    var body: some View {
        PanelView(state: state, scrollable: false)
            .background(scheme == .dark ? Color(red: 0.145, green: 0.145, blue: 0.155) : Color(red: 0.965, green: 0.965, blue: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 18, y: 8)
    }
}

/// A slice of the menu bar: a couple of neighbouring extras, our item, the clock.
private struct MenuBarStrip: View {
    let state: DisplayState
    let scheme: ColorScheme
    var highlighted = false
    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            BarView(state: state)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(highlighted ? 0.12 : 0)))
            Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Text("Mon 16 Nov  10:00").font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.42))
    }
}

private struct MenuBarMock: View {
    let state: DisplayState
    let scheme: ColorScheme
    var body: some View {
        MenuBarStrip(state: state, scheme: scheme)
            .frame(width: 520)
            .background(Backdrop(scheme: scheme))
    }
}

private struct Composite: View {
    let state: DisplayState
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            MenuBarStrip(state: state, scheme: scheme, highlighted: true)
            PanelCard(state: state, scheme: scheme)
                .padding(.trailing, 150)
                .padding(.bottom, 40)
        }
        .frame(width: 640)
        .background(Backdrop(scheme: scheme))
    }
}

private struct BarStyles: View {
    let state: DisplayState
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach([BarStyle.bars, .text, .icon], id: \.self) { style in
                var s = state
                let _ = (s.barStyle = style)
                MenuBarStrip(state: s, scheme: scheme)
            }
            MenuBarStrip(state: PreviewFixture.edgeState, scheme: scheme)
            MenuBarStrip(state: DisplayState(), scheme: scheme)
        }
        .frame(width: 1000)
        .background(Backdrop(scheme: scheme))
    }
}

extension PreviewFixture {
    /// Edge cases: warning/critical meters, a stale paused Claude, an OpenRouter in dollars,
    /// an error, a hidden agent.
    static var edgeState: DisplayState {
        var s = state
        var list = providers
        // OpenRouter without a key limit and no baseline: dollars.
        list[0].money?.limit = nil
        list[0].status = "No key limit"
        list[0].money?.spend = 4.20
        // OpenCode warning + critical.
        list[1].limits[0].percent = 78
        list[1].limits[1].percent = 93
        list[1].error = "OpenCode did not answer; showing the last reading"
        // Claude: sign-in expired, previous limits kept stale.
        list[4].status = "Sign-in expired"
        list[4].hint = "Claude Code's saved sign-in expired. Start Claude Code, or run `claude auth login`, to refresh it."
        list[4].limits = list[4].limits.map { var l = $0; l.stale = true; return l }
        s.providers = list
        s.visibility = [.grok: false]
        s.order = "claude,opencode,openrouter,grok,codex"
        return s
    }
}
