import Foundation

/// Composite text for the bar ("text" style), the status item tooltip and the
/// panel rows. Ported from `Model.js` and the text bindings in `Panel.qml`.
///
/// Public API (`history` defaults to `.empty`, `warn`/`critical` to 70/90, `now` is epoch ms):
/// - `Summary.compactText(_ provider:, history:, warn:, critical:) -> String`
///       "5h 12% · 7d 45%", "7d 2% · bot —" (stale), OpenRouter "$4.20" or "50%"
///       (OpenRouter account-wide: "$20.81 credits left · $49.93 this month", also its tooltip line);
///       the provider's status when it has no windows
/// - `Summary.providerTooltip(_ provider:, history:, now:, warn:, critical:) -> String`
///       "Claude · Max 5x\n  Session (5-hour): 12% · Resets in 4h 48m\n…\n<error>"
/// - `Summary.tooltip(_ providers: [Provider], history:, now:, warn:, critical:) -> String`
///       blocks joined by a blank line; "No AI agents found" for none
/// - `Summary.allHiddenTooltip` — tooltip when agents exist but every one is switched off
/// - `Summary.activityText(_ provider:) -> String`  "Today · 4 prompts · 320K tokens", "This week · …", ""
/// - `Summary.windowValueText(_ window:) -> String` panel row value: "$4.20" | "$20.81 left" |
///       "$3.10 this month" (value rows) | "—" (stale) | "45%"
/// - `Summary.windowCaption(_ window:, now:) -> String`
///       "$8.00 of $12.00 · Resets in 3d 4h · stale reading · over the previous cycle"
/// - `Summary.moneySummary(_ money: Money) -> String`  "$30.00 credits left · $20.00 monthly limit" | "No key limit"
///       | "" for the account-wide (management key) block
/// - `Summary.budgetValueText(_ budget: Budget) -> String`  "$3.00 / $10.00"
/// - `Summary.heroPercentText(_ providers:, history:, warn:, critical:) -> String` highest meter "%", ""
public enum Summary {
    static let dot = " \u{00B7} "

    public static let noAgents = "No AI agents found"
    public static let allHiddenTooltip = "All agents are hidden from the bar\nOpen The Agentic Apple to show one"

    public static func compactText(_ provider: Provider?, history: CycleHistory = .empty,
                                   warn: Double = Meters.defaultWarn, critical: Double = Meters.defaultCritical) -> String {
        if Meters.isAccountWide(provider) { return accountWideText(provider) }
        let windows = Meters.windowsFor(provider, history: history, warn: warn, critical: critical)
        if windows.isEmpty { return provider?.status ?? "" }
        return windows.map { w -> String in
            if w.key == "cycle" {
                return w.mode == .dollars ? Format.currency(w.spend) : Format.percentText(w.percent)
            }
            if w.stale { return w.short + " " + Format.dash }
            return w.short + " " + Format.percentText(w.percent)
        }.joined(separator: dot)
    }

    /// Account-wide OpenRouter in the Percentages bar style: "$20.81 · 82%"
    /// (the percent only when the month has a baseline).
    public static func accountWideBarText(_ provider: Provider?, history: CycleHistory = .empty,
                                          warn: Double = Meters.defaultWarn, critical: Double = Meters.defaultCritical) -> String {
        let dollars = Meters.barDollarsText(provider, history: history, warn: warn, critical: critical)
        guard let meter = Meters.barMeters(provider, history: history, warn: warn, critical: critical).first else { return dollars }
        return [dollars, windowValueText(meter)].filter { !$0.isEmpty }.joined(separator: dot)
    }

    /// Account-wide OpenRouter: "$20.81 credits left · $49.93 this month".
    static func accountWideText(_ provider: Provider?) -> String {
        var parts: [String] = []
        if let credits = Meters.creditsLeft(provider) { parts.append(Format.currency(credits) + " credits left") }
        let spend = provider?.money?.spend ?? 0
        parts.append(Format.currency(spend.isFinite ? max(0, spend) : 0) + " this month")
        return parts.joined(separator: dot)
    }

    public static func providerTooltip(_ provider: Provider?, history: CycleHistory = .empty, now: Double,
                                       warn: Double = Meters.defaultWarn, critical: Double = Meters.defaultCritical) -> String {
        guard let provider else { return "" }
        var lines: [String] = []
        var head = provider.name
        if !provider.tier.isEmpty { head += dot + provider.tier }
        lines.append(head)
        if !provider.status.isEmpty { lines.append(provider.status) }
        if Meters.isAccountWide(provider) {
            // The panel has the per-key rows; the tooltip keeps to the account.
            lines.append("  " + accountWideText(provider))
            if !provider.error.isEmpty { lines.append(provider.error) }
            return lines.joined(separator: "\n")
        }
        for w in Meters.windowsFor(provider, history: history, warn: warn, critical: critical) {
            let value = w.mode == .dollars ? Format.currency(w.spend) : Format.percentText(w.percent)
            var line = "  " + w.detail + ": " + value
            if w.mode == .meter, let e = w.effectiveLimit, e != 0 { line += " of " + Format.currency(e) }
            let reset = Format.resetText(w.resetsAt, now: now)
            if !reset.isEmpty { line += dot + reset }
            if w.stale { line += dot + "stale" }
            lines.append(line)
        }
        if !provider.error.isEmpty { lines.append(provider.error) }
        return lines.joined(separator: "\n")
    }

    public static func tooltip(_ providers: [Provider], history: CycleHistory = .empty, now: Double,
                               warn: Double = Meters.defaultWarn, critical: Double = Meters.defaultCritical) -> String {
        if providers.isEmpty { return noAgents }
        return providers.map { providerTooltip($0, history: history, now: now, warn: warn, critical: critical) }
            .joined(separator: "\n\n")
    }

    public static func activityText(_ provider: Provider?) -> String {
        guard let activity = provider?.activity else { return "" }
        var parts: [String] = []
        if activity.prompts > 0 { parts.append(Format.count(Double(activity.prompts)) + " prompts") }
        if activity.tokens > 0 { parts.append(Format.tokensText(Double(activity.tokens))) }
        if parts.isEmpty { return "" }
        return (activity.period == "week" ? "This week" : "Today") + dot + parts.joined(separator: dot)
    }

    public static func windowValueText(_ window: MeterWindow) -> String {
        if window.mode == .dollars {
            let value = Format.currency(window.spend)
            return window.valueSuffix.isEmpty ? value : value + " " + window.valueSuffix
        }
        if window.stale { return Format.dash }
        // Account-wide month over its average: say how far ("120%"), the bar fill is capped.
        return Format.percentText(window.percent, upTo: window.baselineText.isEmpty ? 100 : 9999)
    }

    public static func windowCaption(_ window: MeterWindow, now: Double) -> String {
        var parts: [String] = []
        if window.mode == .meter, let e = window.effectiveLimit, e != 0 {
            let of = Format.currency(window.spend) + " of " + Format.currency(e)
            parts.append(window.baselineText.isEmpty ? of : of + " " + window.baselineText)
        }

        let reset = Format.resetText(window.resetsAt, now: now)
        if !reset.isEmpty { parts.append(reset) }
        if window.stale { parts.append("stale reading") }
        if window.over { parts.append(window.overNote) }
        return parts.joined(separator: dot)
    }

    public static func moneySummary(_ money: Money) -> String {
        // Account-wide: credits have their own row and there is no single key limit.
        if money.label == Money.accountWideLabel { return "" }
        var parts: [String] = []
        if let credits = money.credits { parts.append(Format.currency(max(0, credits)) + " credits left") }
        if let limit = money.limit, limit.isFinite, limit > 0 {
            parts.append(Format.currency(limit) + " " + Format.intervalName(money.resetInterval).lowercased() + " limit")
        } else {
            parts.append("No key limit")
        }
        return parts.joined(separator: dot)
    }

    public static func budgetValueText(_ budget: Budget) -> String {
        Format.currency(budget.spend) + " / " + Format.currency(budget.limit)
    }

    public static func heroPercentText(_ providers: [Provider], history: CycleHistory = .empty,
                                       warn: Double = Meters.defaultWarn, critical: Double = Meters.defaultCritical) -> String {
        guard let top = Meters.highestMeterPercent(providers, history: history, warn: warn, critical: critical) else { return "" }
        return Format.percentText(top)
    }
}
