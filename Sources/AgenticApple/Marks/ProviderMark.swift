import SwiftUI
import AgenticCore

/// An agent's monochrome mark at a given height (points). It draws in the
/// inherited foreground style and is never tinted by meter state. Width follows
/// the mark's own aspect (OpenRouter is wider, OpenCode narrower).
public struct ProviderMark: View {
    public let id: ProviderID
    public let size: CGFloat

    public init(_ id: ProviderID, size: CGFloat) {
        self.id = id
        self.size = size
    }

    /// The width this mark occupies at `size`, for callers laying out a bar.
    public static func width(for id: ProviderID, size: CGFloat) -> CGFloat {
        switch id {
        case .openrouter: return (size * MarkPaths.openRouter.aspect).rounded()
        case .opencode: return (size * 0.8).rounded()
        case .claude: return (size * MarkPaths.claude.aspect).rounded()
        case .grok, .codex: return size.rounded()
        }
    }

    public var body: some View {
        Group {
            switch id {
            case .openrouter: vector(MarkPaths.openRouter, evenOdd: true)
            case .opencode: OpenCodeMark(size: size)
            case .grok: vector(MarkPaths.grok, evenOdd: false)
            case .codex: vector(MarkPaths.codex, evenOdd: true)
            case .claude: vector(MarkPaths.claude, evenOdd: false)
            }
        }
        .frame(width: Self.width(for: id, size: size), height: size.rounded())
        .accessibilityLabel(Text(id.displayName))
    }

    private func vector(_ mark: VectorMark, evenOdd: Bool) -> some View {
        mark.fill(style: FillStyle(eoFill: evenOdd, antialiased: true))
    }
}

/// The "Agent Meters" robot shown in the panel hero (a vector stand-in for the
/// reference's Nerd Font robot glyph). Square, foreground-coloured.
public struct AgentMetersGlyph: View {
    public let size: CGFloat

    public init(size: CGFloat = 22) {
        self.size = size
    }

    public var body: some View {
        MarkPaths.robot
            .fill(style: FillStyle(eoFill: true, antialiased: true))
            .frame(width: size.rounded(), height: size.rounded())
            .accessibilityLabel(Text("Agent Meters"))
    }
}
