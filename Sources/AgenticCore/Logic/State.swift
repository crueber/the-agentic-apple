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
/// - `Meters.barWindows(...) -> [MeterWindow]`          first 3 windows (what the bar considers)
/// - `Meters.barMeters(...) -> [MeterWindow]`           bar windows actually drawn as mini meters
/// - `Meters.barDollarsText(...) -> String`             OpenRouter's "$4.20" bar text, "" when none
/// - `Meters.providerColor(...) -> MeterState`          colour of the bar text for a provider
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

    public init(key: String, label: String, short: String, detail: String, percent: Double,
                resetsAt: Double = 0, stale: Bool = false, limited: Bool = false,
                state: MeterState = .normal, color: MeterState = .normal, mode: WindowMode = .meter,
                meterVisible: Bool = true, spend: Double? = nil, limit: Double? = nil,
                effectiveLimit: Double? = nil, over: Bool = false, previous: Cycle? = nil,
                credits: Double? = nil, totalCredits: Double? = nil, resetInterval: String = "",
                keyLabel: String = "") {
        self.key = key; self.label = label; self.short = short; self.detail = detail
        self.percent = percent; self.resetsAt = resetsAt; self.stale = stale; self.limited = limited
        self.state = state; self.color = color; self.mode = mode; self.meterVisible = meterVisible
        self.spend = spend; self.limit = limit; self.effectiveLimit = effectiveLimit; self.over = over
        self.previous = previous; self.credits = credits; self.totalCredits = totalCredits
        self.resetInterval = resetInterval; self.keyLabel = keyLabel
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
        return MeterWindow(
            key: "cycle", label: "This cycle", short: "$",
            detail: limited ? "Key limit" : "Cycle spend",
            percent: used, resetsAt: money.resetsAt, stale: false, limited: false,
            state: color == .yellow ? .normal : color, color: color,
            mode: (limited || meterVisible) ? .meter : .dollars,
            meterVisible: meterVisible, spend: spend, limit: keyLimit, effectiveLimit: effectiveLimit,
            over: over, previous: previous, credits: money.credits, totalCredits: money.totalCredits,
            resetInterval: money.resetInterval, keyLabel: money.label)
    }

    public static func windowsFor(_ provider: Provider?, history: CycleHistory = .empty,
                                  warn: Double = defaultWarn, critical: Double = defaultCritical) -> [MeterWindow] {
        guard let provider else { return [] }
        if provider.id == .openrouter {
            return openrouterWindow(provider, history: history, warn: warn, critical: critical).map { [$0] } ?? []
        }
        return provider.limits.map { limit in
            let state: MeterState = limit.limited ? .critical : stateOf(limit.percent, warn: warn, critical: critical)
            return MeterWindow(key: limit.key, label: limit.label, short: limit.short, detail: limit.label,
                               percent: limit.percent, resetsAt: limit.resetsAt, stale: limit.stale,
                               limited: limit.limited, state: state, color: state, mode: .meter,
                               meterVisible: true)
        }
    }

    public static func barWindows(_ provider: Provider?, history: CycleHistory = .empty,
                                  warn: Double = defaultWarn, critical: Double = defaultCritical) -> [MeterWindow] {
        Array(windowsFor(provider, history: history, warn: warn, critical: critical).prefix(barLimit))
    }

    /// The bar windows drawn as mini meters: meter mode, and for OpenRouter only when
    /// `meterVisible` (zero spend or no baseline draws the mark only).
    public static func barMeters(_ provider: Provider?, history: CycleHistory = .empty,
                                 warn: Double = defaultWarn, critical: Double = defaultCritical) -> [MeterWindow] {
        barWindows(provider, history: history, warn: warn, critical: critical).filter {
            $0.mode == .meter && (provider?.id != .openrouter || $0.meterVisible)
        }
    }

    /// OpenRouter's dollar figure next to its mark in the bar ("bars" style), or "".
    /// Zero spend draws nothing (mark only).
    public static func barDollarsText(_ provider: Provider?, history: CycleHistory = .empty,
                                      warn: Double = defaultWarn, critical: Double = defaultCritical) -> String {
        guard provider?.id == .openrouter,
              let w = windowsFor(provider, history: history, warn: warn, critical: critical).first,
              w.mode == .dollars, let spend = w.spend, spend > 0 else { return "" }
        return Format.currency(spend)
    }

    public static func providerColor(_ provider: Provider?, history: CycleHistory = .empty,
                                     warn: Double = defaultWarn, critical: Double = defaultCritical) -> MeterState {
        let windows = windowsFor(provider, history: history, warn: warn, critical: critical)
        if windows.contains(where: { $0.limited }) { return .critical }
        return highest(windows)?.color ?? .normal
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
