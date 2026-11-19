import Foundation

/// Text formatting shared by the bar, the panel and the CLI. Ported from the
/// reference plugin's `Model.js`; every output string matches it exactly.
///
/// Public API (all `static`, pure, no wall clock — pass `now` in epoch ms):
/// - `Format.percentText(_ value: Double?) -> String`          "45.5%", "0%", "—" for nil
/// - `Format.currency(_ value: Double?) -> String`             "$1,234.50", "-$3.00", "—" for nil
/// - `Format.count(_ value: Double?) -> String`                "135", "1.2K", "84K", "1.1M", "2B", "—"
/// - `Format.resetText(_ resetsAt: Double, now: Double) -> String`
///       "" (unknown), "Reset is due", "Resets in 12m", "Resets in 4h 48m", "Resets in 4d 0h"
/// - `Format.updatedText(_ lastFetchMs: Double, now: Double) -> String`
///       "" (never), "Updated just now", "Updated 42s ago", "Updated 5m ago", "Updated 2h ago"
/// - `Format.updatedAgo(_ lastFetchMs: Double, now: Double) -> String`  the same without "Updated "
/// - `Format.tokensText(_ value: Double?) -> String`           "84K tokens", "" when 0
/// - `Format.intervalName(_ value: String) -> String`          "Weekly" | "Daily" | "Yearly" | "No reset" | "Monthly"
/// - `Format.jsRound(_ x: Double) -> Double`                   JavaScript `Math.round` (half rounds up)
public enum Format {
    public static let dash = "\u{2014}"

    /// JavaScript `Math.round`: halves round towards +∞.
    public static func jsRound(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return (x + 0.5).rounded(.down)
    }

    /// A whole-number Double as text without ".0" (falls back to Swift's description when huge).
    static func integerText(_ x: Double) -> String {
        if x.isFinite, abs(x) < 9e15 { return String(Int64(x)) }
        return String(x)
    }

    public static func percentText(_ value: Double?) -> String {
        guard let n = value, n.isFinite else { return dash }
        let rounded = jsRound(Sanitize.clamp(n, 0, 100) * 10) / 10
        let body = rounded.truncatingRemainder(dividingBy: 1) == 0
            ? integerText(rounded)
            : String(format: "%.1f", rounded)
        return body + "%"
    }

    public static func currency(_ value: Double?) -> String {
        guard let n = value, n.isFinite else { return dash }
        let sign = n < 0 ? "-" : ""
        let fixed = String(format: "%.2f", abs(n))
        let parts = fixed.split(separator: ".", omittingEmptySubsequences: false)
        let whole = groupThousands(String(parts[0]))
        let frac = parts.count > 1 ? "." + parts[1] : ""
        return sign + "$" + whole + frac
    }

    static func groupThousands(_ digits: String) -> String {
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    /// `toFixed(1)` with a trailing ".0" removed.
    static func oneDecimal(_ x: Double) -> String {
        let s = String(format: "%.1f", x)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    public static func count(_ value: Double?) -> String {
        guard let n = value, n.isFinite else { return dash }
        let a = abs(n)
        if a >= 1e9 { return oneDecimal(n / 1e9) + "B" }
        if a >= 1e6 { return oneDecimal(n / 1e6) + "M" }
        if a >= 1e4 { return integerText(jsRound(n / 1e3)) + "K" }
        if a >= 1e3 { return oneDecimal(n / 1e3) + "K" }
        return integerText(jsRound(n))
    }

    public static func count(_ value: Int) -> String { count(Double(value)) }

    public static func resetText(_ resetsAt: Double, now: Double) -> String {
        guard resetsAt.isFinite, resetsAt > 0, now.isFinite else { return "" }
        let delta = resetsAt - now
        if delta <= 0 { return "Reset is due" }
        let minutes = jsRound(delta / 60000)
        if minutes < 60 { return "Resets in \(integerText(max(1, minutes)))m" }
        let hours = (minutes / 60).rounded(.down)
        if hours < 48 {
            return "Resets in \(integerText(hours))h \(integerText(minutes.truncatingRemainder(dividingBy: 60)))m"
        }
        let days = (hours / 24).rounded(.down)
        return "Resets in \(integerText(days))d \(integerText(hours.truncatingRemainder(dividingBy: 24)))h"
    }

    public static func updatedText(_ lastFetchMs: Double, now: Double) -> String {
        guard lastFetchMs.isFinite, lastFetchMs > 0, now.isFinite else { return "" }
        let seconds = max(0, jsRound((now - lastFetchMs) / 1000))
        if seconds < 15 { return "Updated just now" }
        if seconds < 90 { return "Updated \(integerText(seconds))s ago" }
        let minutes = jsRound(seconds / 60)
        if minutes < 90 { return "Updated \(integerText(minutes))m ago" }
        return "Updated \(integerText(jsRound(minutes / 60)))h ago"
    }

    public static func updatedAgo(_ lastFetchMs: Double, now: Double) -> String {
        let text = updatedText(lastFetchMs, now: now)
        return text.hasPrefix("Updated ") ? String(text.dropFirst("Updated ".count)) : text
    }

    public static func tokensText(_ value: Double?) -> String {
        guard let n = value, n.isFinite, n > 0 else { return "" }
        return count(n) + " tokens"
    }

    public static func intervalName(_ value: String) -> String {
        let text = value.lowercased()
        if text.contains("week") { return "Weekly" }
        if text.contains("day") || text.contains("daily") { return "Daily" }
        if text.contains("year") || text.contains("annual") { return "Yearly" }
        if text == "total" || text == "lifetime" || text == "none" { return "No reset" }
        return "Monthly"
    }
}
