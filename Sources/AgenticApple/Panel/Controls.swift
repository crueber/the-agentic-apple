import SwiftUI
import AgenticCore

/// A row meter: rounded track and an animated fill.
struct MeterBar: View {
    var percent: Double
    var color: Color
    var dimmed = false
    var height: CGFloat = 5
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, percent / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track(scheme))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * fraction))
                    .opacity(dimmed ? 0.4 : 1)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: percent)
        .accessibilityHidden(true)
    }
}

/// A compact switch drawn in SwiftUI (renders identically live and in
/// ImageRenderer previews, which can't draw the AppKit-backed switch).
struct MiniSwitch: View {
    var isOn: Bool
    var label: String
    var action: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { action(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.track(scheme).opacity(scheme == .dark ? 1.4 : 1.3)))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(isOn ? 0 : 0.06), lineWidth: 0.5))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 0.8, y: 0.5)
                    .padding(1.5)
            }
            .frame(width: 26, height: 15)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isButton)
        .help(isOn ? "Shown in the menu bar" : "Hidden from the menu bar")
    }
}

/// A borderless icon button with a soft hover fill, like Control Center's.
struct HoverIconButton: View {
    var systemName: String
    var help: String
    var spinning = false
    var enabled = true
    var action: () -> Void
    @State private var hovering = false
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(angle))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering && enabled ? 0.09 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .onChange(of: spinning) { _, now in spin(now) }
        .onAppear { spin(spinning) }
    }

    private func spin(_ on: Bool) {
        if on {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
        }
    }
}
