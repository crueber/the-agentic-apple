import SwiftUI
import AppKit
import AgenticCore

/// Colours for meter states. Resolved per colour scheme explicitly (not through
/// dynamic NSColors) so the live bar, the panel and ImageRenderer previews agree.
struct Palette: Equatable {
    /// User overrides as "#rrggbb"; nil = system default.
    var warningHex: String? = nil
    var criticalHex: String? = nil

    static let defaultWarningLight = Color(red: 0.86, green: 0.40, blue: 0.0)   // legible orange on light bars
    static let defaultWarningDark = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let defaultCriticalLight = Color(red: 0.84, green: 0.16, blue: 0.13)
    static let defaultCriticalDark = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let compareLight = Color(red: 0.62, green: 0.47, blue: 0.05)
    static let compareDark = Color(red: 0.85, green: 0.71, blue: 0.36)        // reference #d9b45b

    func color(_ state: MeterState, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch state {
        case .normal: return dark ? Color.primary : Color.primary.opacity(0.86)
        case .warning:
            return warningHex.flatMap(Color.init(hex:)) ?? (dark ? Self.defaultWarningDark : Self.defaultWarningLight)
        case .critical:
            return criticalHex.flatMap(Color.init(hex:)) ?? (dark ? Self.defaultCriticalDark : Self.defaultCriticalLight)
        case .yellow:
            return dark ? Self.compareDark : Self.compareLight
        }
    }

    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.11)
    }
}

extension Color {
    /// "#rrggbb" / "rrggbb"; nil otherwise.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// "#rrggbb" in sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func c(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(ns.redComponent), c(ns.greenComponent), c(ns.blueComponent))
    }
}
