import Foundation

/// Meter state and the windows (meters) each provider contributes. Ported from
/// the reference plugin's `Model.js`.
///
/// Colour rules (README "Colours and thresholds"), per window:
///   1. `.critical` — percent ≥ critical (default 90), or the source marks the window `limited`
///   2. `.warning`  — percent ≥ warn (default 70)
///   3. `.yellow`   — OpenRouter only: this cycle is over the previous completed cycle
///   4. `.normal`   — everything else (theme foreground). Marks are never tinted.
///
/// Public API:
/// - `enum MeterState: String { normal, warning, critical, yellow }`
/// - `enum WindowMode: String { meter, dollars }`
/// - `struct MeterWindow` — one row/meter: key, label, short, detail, percent (0…100), resetsAt (ms),
///   stale, limited, state (never .yellow), color (may be .yellow), mode, meterVisible,
///   spend/limit/effectiveLimit (dollars, OpenRouter only), over, previous (Cycle?),
///   credits/totalCredits, resetInterval, keyLabel (OpenRouter masked key label)
/// - `Meters.defaultWarn` (70), `Meters.defaultCritical` (90)
/// - `Meters.stateOf(_ percent: Double?, warn:, critical:) -> MeterState`
/// - `Meters.highest(_ windows: [MeterWindow]) -> MeterWindow?`   first with the largest percent
/// - `Meters.highest(_ limits: [Limit]) -> Limit?`
/// - `Meters.openrouterWindow(_ provider:, history:, warn:, critical:) -> MeterWindow?`
/// - `Meters.windowsFor(_ provider:, history:, warn:, critical:) -> [MeterWindow]`  panel rows, in order
///       (OpenRouter: the money window, then its `limits` — management key: Credits, then keys)
/// - `Meters.periodPhrase(_ interval: String) -> String`  "this month" | "this week" | "today"
/// - `Meters.barWindows(...) -> [MeterWindow]`          first 3 windows (what the bar considers)
/// - `Meters.barMeters(...) -> [MeterWindow]`           bar windows actually drawn as mini meters
/// - `Meters.barDollarsText(...) -> String`             OpenRouter's "$4.20" bar text, "" when none
///       (account-wide: credits left, else this month's spend; no meters drawn)
/// - `Meters.barDollarsColor(...) -> MeterState`        its colour (normal account-wide)
/// - `Meters.isAccountWide(_:)`, `Meters.creditsLeft(_:) -> Double?`  OpenRouter management-key mode
///   (`windowsFor(..., keyRows:)` keeps only the first N `key-` rows)
/// - `Meters.providerColor(...) -> MeterState`          colour of the bar text for a provider (meters
///       ranked first; OpenRouter's yellow only when no other window is elevated)
/// - `Meters.summaryWindow(_ windows:) -> MeterWindow?` headline window: highest live meter, else highest
/// - `Meters.isAlarming(...) -> Bool`                   providerColor == .critical
/// - `Meters.highestMeterPercent(_ providers:, history:, warn:, critical:) -> Double?`  hero figure
///
/// All `warn`/`critical` parameters default to 70/90 and `history` to `.empty`.
public enum MeterState: String, Codable, Sendable {
    case normal, warning, critical, yellow
}

public enum WindowMode: String, Codable, Sendable {
    case meter, dollars
}

public struct MeterWindow: Equatable, Sendable {
    public var key: String
    public var label: String
    public var short: String
    /// Panel row title.
    public var detail: String
    public var percent: Double
    public var resetsAt: Double
    public var stale: Bool
    public var limited: Bool
    /// Threshold state; `.yellow` is reported as `.normal` here.
    public var state: MeterState
    /// The colour to draw with (may be `.yellow`).
    public var color: MeterState
    public var mode: WindowMode
    /// OpenRouter: whether a meter (rather than just the mark) belongs in the bar.
    public var meterVisible: Bool
    public var spend: Double?
    public var limit: Double?
    public var effectiveLimit: Double?
    public var over: Bool
    public var previous: Cycle?
    public var credits: Double?
    public var totalCredits: Double?
    public var resetInterval: String
    public var keyLabel: String
    /// Dollars-mode value rows: a word after the figure ("left", "this month").
    public var valueSuffix: String

    public init(key: String, label: String, short: String, detail: String, percent: Double,
                resetsAt: Double = 0, stale: Bool = false, limited: Bool = false,
                state: MeterState = .normal, color: MeterState = .normal, mode: WindowMode = .meter,
                meterVisible: Bool = true, spend: Double? = nil, limit: Double? = nil,
                effectiveLimit: Double? = nil, over: Bool = false, previous: Cycle? = nil,
                credits: Double? = nil, totalCredits: Double? = nil, resetInterval: String = "",
                keyLabel: String = "", valueSuffix: String = "") {
        self.key = key; self.label = label; self.short = short; self.detail = detail
        self.percent = percent; self.resetsAt = resetsAt; self.stale = stale; self.limited = limited
        self.state = state; self.color = color; self.mode = mode; self.meterVisible = meterVisible
        self.spend = spend; self.limit = limit; self.effectiveLimit = effectiveLimit; self.over = over
        self.previous = previous; self.credits = credits; self.totalCredits = totalCredits
        self.resetInterval = resetInterval; self.keyLabel = keyLabel; self.valueSuffix = valueSuffix
    }
}

public enum Meters {
    public static let defaultWarn: Double = 70
    public static let defaultCritical: Double = 90
    /// The bar draws at most this many meters per agent.
    public static let barLimit = 3

    public static func stateOf(_ percent: Double?, warn: Double = defaultWarn, critical: Double = defaultCritical) -> MeterState {
        let n = (percent?.isFinite ?? false) ? percent! : 0
        if n >= critical { return .critical }
        if n >= warn { return .warning }
        return .normal
    }

    public static func highest(_ windows: [MeterWindow]) -> MeterWindow? {
        var best: MeterWindow?
        for w in windows where best == nil || w.percent > best!.percent { best = w }
        return best
    }

    public static func highest(_ limits: [Limit]) -> Limit? {
        var best: Limit?
        for l in limits where best == nil || l.percent > best!.percent { best = l }
        return best
    }

    public static func openrouterWindow(_ provider: Provider?, history: CycleHistory = .empty,
                                        warn: Double = defaultWarn, critical: Double = defaultCritical) -> MeterWindow? {
        guard let money = provider?.money else { return nil }
        let previous = history.normalized().previous
        let spend = money.spend.isFinite ? max(0, money.spend) : 0
        let keyLimit: Double? = {
            guard let l = money.limit, l.isFinite, l > 0 else { return nil }
            return l
        }()
        let limited = keyLimit != nil
        let over = previous.map { spend > $0.spend } ?? false
        let effectiveLimit: Double? = keyLimit ?? ((previous?.spend ?? 0) > 0 ? previous!.spend : nil)
        var used: Double = 0
        if let e = effectiveLimit, e > 0 { used = Sanitize.clamp(spend / e * 100, 0, 100) }
        let meterVisible = limited ? spend > 0 : (previous.map { $0.spend > 0 && spend <= $0.spend } ?? false)
        var color: MeterState = .normal
        if limited || meterVisible {
            if used >= critical { color = .critical } else if used >= warn { color = .warning }
        }
        if over { color = .yellow }
        let detail: String
        if limited { detail = "Key limit" }
        else if money.label == Money.accountWideLabel { detail = Money.accountWideLabel + " \u{00B7} " + periodPhrase(money.resetInterval) }
        else { detail = "Cycle spend" }
        return MeterWindow(
            key: "cycle", label: "This cycle", short: "$",
            detail: detail,
            percent: used, resetsAt: money.resetsAt, stale: false, limited: false,
            state: color == .yellow ? .normal : color, color: color,
            mode: (limited || meterVisible) ? .meter : .dollars,
            meterVisible: meterVisible, spend: spend, limit: keyLimit, effectiveLimit: effectiveLimit,
            over: over, previous: previous, credits: money.credits, totalCredits: money.totalCredits,
            resetInterval: money.resetInterval, keyLabel: money.label)
    }

    /// `keyRows`: OpenRouter account-wide only — how many key rows to keep
    /// (the `openrouterKeyRows` setting); nil keeps all the collector returned.
    public static func windowsFor(_ provider: Provider?, history: CycleHistory = .empty,
                                  warn: Double = defaultWarn, critical: Double = defaultCritical,
                                  keyRows: Int? = nil) -> [MeterWindow] {
        guard let provider else { return [] }
        if provider.id == .openrouter {
            // The money window first; a management key adds Credits and the keys
            // used most this month after it (in the collector's order).
            var windows = openrouterWindow(provider, history: history, warn: warn, critical: critical).map { [$0] } ?? []
            var keysLeft = max(0, keyRows ?? Int.max)
            for limit in provider.limits {
                if limit.key.hasPrefix("key-") {
                    if keysLeft == 0 { continue }
                    keysLeft -= 1
                }
                windows.append(limitWindow(limit, warn: warn, critical: critical))
            }
            return windows
        }
        return provider.limits.map { limitWindow($0, warn: warn, critical: critical) }
    }

    /// OpenRouter with a management key ("All keys" money block).
    public static func isAccountWide(_ provider: Provider?) -> Bool {
        provider?.id == .openrouter && provider?.money?.label == Money.accountWideLabel
    }

    /// Account-wide credits left, nil when OpenRouter did not report them.
    public static func creditsLeft(_ provider: Provider?) -> Double? {
        guard isAccountWide(provider) else { return nil }
        return provider?.limits.first { $0.key == "credits" }?.amount
    }

    static func limitWindow(_ limit: Limit, warn: Double, critical: Double) -> MeterWindow {
        if let amount = limit.amount {
            // A value row: a dollar figure, no meter, no percent, never coloured.
            return MeterWindow(key: limit.key, label: limit.label, short: limit.short, detail: limit.label,
                               percent: 0, resetsAt: limit.resetsAt, stale: limit.stale, limited: false,
                               mode: .dollars, meterVisible: false, spend: amount,
                               valueSuffix: limit.key == "credits" ? "left" : "this month")
        }
        let state: MeterState = limit.limited ? .critical : stateOf(limit.percent, warn: warn, critical: critical)
        return MeterWindow(key: limit.key, label: limit.label, short: limit.short, detail: limit.label,
                           percent: limit.percent, resetsAt: limit.resetsAt, stale: limit.stale,
                           limited: limit.limited, state: state, color: state, mode: .meter,
                           meterVisible: true)
    }

    /// "this month" / "this week" / "today" for a reset interval.
    public static func periodPhrase(_ interval: String) -> String {
        let text = interval.lowercased()
        if text.contains("week") { return "this week" }
        if text.contains("day") || text.contains("daily") { return "today" }
        return "this month"
    }

    public static func barWindows(_ provider: Provider?, history: CycleHistory = .empty,
                                  warn: Double = defaultWarn, critical: Double = defaultCritical) -> [MeterWindow] {
        Array(windowsFor(provider, history: history, warn: warn, critical: critical).prefix(barLimit))
    }

    /// The bar windows drawn as mini meters: meter mode, and for OpenRouter only when
    /// `meterVisible` (zero spend or no baseline draws the mark only).
    public static func barMeters(_ provider: Provider?, history: CycleHistory = .empty,
                                 warn: Double = defaultWarn, critical: Double = defaultCritical) -> [MeterWindow] {
        // Account-wide OpenRouter draws its credits figure only, never meters.
        if isAccountWide(provider) { return [] }
        return barWindows(provider, history: history, warn: warn, critical: critical).filter {
            $0.mode == .meter && (provider?.id != .openrouter || $0.meterVisible)
        }
    }

    /// OpenRouter's dollar figure next to its mark in the bar ("bars" style), or "".
    /// Zero spend draws nothing (mark only).
    public static func barDollarsText(_ provider: Provider?, history: CycleHistory = .empty,
                                      warn: Double = defaultWarn, critical: Double = defaultCritical) -> String {
        if isAccountWide(provider) {
            // Credits left; without /credits, this month's spend.
            if let credits = creditsLeft(provider) { return Format.currency(credits) }
            let spend = provider?.money?.spend ?? 0
            return spend.isFinite && spend > 0 ? Format.currency(spend) : ""
        }
        guard provider?.id == .openrouter,
              let w = windowsFor(provider, history: history, warn: warn, critical: critical).first,
              w.mode == .dollars, let spend = w.spend, spend > 0 else { return "" }
        return Format.currency(spend)
    }

    /// Colour of OpenRouter's bar figure: the money window's, or normal account-wide.
    public static func barDollarsColor(_ provider: Provider?, history: CycleHistory = .empty,
                                       warn: Double = defaultWarn, critical: Double = defaultCritical) -> MeterState {
        if isAccountWide(provider) { return .normal }
        return windowsFor(provider, history: history, warn: warn, critical: critical).first?.color ?? .normal
    }

    public static func providerColor(_ provider: Provider?, history: CycleHistory = .empty,
                                     warn: Double = defaultWarn, critical: Double = defaultCritical) -> MeterState {
        let windows = windowsFor(provider, history: history, warn: warn, critical: critical)
        if windows.contains(where: { $0.limited }) { return .critical }
        // Rank meters first, so OpenRouter's dollars window (percent 100 when over the
        // previous cycle) never masks a warning or critical row; yellow only when
        // nothing else is elevated.
        let top = summaryWindow(windows)?.color ?? .normal
        if top == .normal, windows.contains(where: { $0.color == .yellow }) { return .yellow }
        return top
    }

    /// The window a provider's headline figure comes from: the highest meter-mode
    /// window (live ones first), else the highest of all.
    public static func summaryWindow(_ windows: [MeterWindow]) -> MeterWindow? {
        let live = windows.filter { !$0.stale }
        let pool = live.isEmpty ? windows : live
        let meters = pool.filter { $0.mode == .meter }
        return highest(meters.isEmpty ? pool : meters)
    }

    public static func isAlarming(_ provider: Provider?, history: CycleHistory = .empty,
                                  warn: Double = defaultWarn, critical: Double = defaultCritical) -> Bool {
        providerColor(provider, history: history, warn: warn, critical: critical) == .critical
    }

    /// Largest meter-mode percent across providers (the panel hero), nil when none.
    public static func highestMeterPercent(_ providers: [Provider], history: CycleHistory = .empty,
                                           warn: Double = defaultWarn, critical: Double = defaultCritical) -> Double? {
        var top: Double?
        for p in providers {
            for w in windowsFor(p, history: history, warn: warn, critical: critical) where w.mode == .meter {
                if top == nil || w.percent > top! { top = w.percent }
            }
        }
        return top
    }
}
