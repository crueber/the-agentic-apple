import AppKit
import SwiftUI
import AgenticCore

/// Renders every mark at bar and panel sizes, light-on-dark and dark-on-light,
/// into one PNG — a visual check for the vector ports.
enum MarkPreview {
    static let barSizes: [CGFloat] = [14, 16, 18]
    static let panelSize: CGFloat = 22

    @MainActor
    static func renderPNG(to url: URL, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    @MainActor
    private static var sheet: some View {
        VStack(spacing: 0) {
            band(foreground: Color(white: 0.93), background: Color(white: 0.11))
            band(foreground: Color(white: 0.08), background: Color(white: 0.96))
        }
        .fixedSize()
    }

    @MainActor
    private static func band(foreground: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(barSizes + [panelSize], id: \.self) { size in
                row(size: size)
            }
            AgentMetersGlyph(size: 44)
            HStack(spacing: 14) {
                ForEach(ProviderID.defaultOrder, id: \.self) { ProviderMark($0, size: 64) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(foreground)
        .background(background)
    }

    @MainActor
    private static func row(size: CGFloat) -> some View {
        HStack(spacing: 8) {
            AgentMetersGlyph(size: size)
            ForEach(ProviderID.defaultOrder, id: \.self) { ProviderMark($0, size: size) }
        }
    }
}
