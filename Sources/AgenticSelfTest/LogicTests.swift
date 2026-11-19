import Foundation
import AgenticCore

/// Ports the reference plugin's scripts/test-model.js, plus cases for the
/// behaviour it leaves untested (schedule, merge, limited, cache files).
enum LogicTests {
    static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        return date.timeIntervalSince1970 * 1000
    }

    static let now = utc(2026, 11, 15, 12)
    static let cycleEnd = utc(2026, 12, 1)
    static let day: Double = 86_400_000

    static func provider(_ id: ProviderID, available: Bool = true, tier: String = "Max 5x",
                         limits: [Limit] = [], money: Money? = nil) -> Provider {
        Provider(id: id, available: available, tier: tier, source: "test", limits: limits, money: money)
    }

    static func limit(_ key: String, _ percent: Double, _ resetsAt: Double = 0,
                      short: String? = nil, stale: Bool = false, limited: Bool = false) -> Limit {
        Limit(key: key, label: key, short: short ?? (key == "session" ? "5h" : key == "weekly" ? "7d" : key),
              percent: percent, resetsAt: resetsAt, limited: limited, stale: stale)
    }

    static func ids(_ list: [Provider]) -> String { list.map(\.id.rawValue).joined(separator: ",") }
    static func ids(_ list: [ProviderID]) -> String { Ordering.serializeOrder(list) }

    static func run(_ t: TestRun) async {
        t.suite("Logic")
        ordering(t)
        states(t)
        formatting(t)
        openrouter(t)
        openrouterAccount(t)
        history(t)
        cache(t)
        text(t)
        schedule(t)
        merge(t)
        mergePaused(t)
    }

    // MARK: order and visibility

    static func ordering(_ t: TestRun) {
        let list = [provider(.claude), provider(.codex), provider(.grok), provider(.opencode),
                    provider(.openrouter), provider(.grok, available: false)]
        t.equal(ids(Ordering.visibleProviders(list, visibility: [:])), "openrouter,opencode,grok,codex,claude")
        t.equal(ids(Ordering.visibleProviders(list, visibility: [.claude: false, .openrouter: false])), "opencode,grok,codex")
        // An unavailable entry never shows, even listed first.
        t.equal(ids(Ordering.visibleProviders([provider(.grok, available: false)], visibility: [:])), "")

        let five = Array(list.prefix(5))
        t.equal(ids(Ordering.orderedProviders(five, visibility: [:], order: "grok,claude")), "grok,claude,openrouter,opencode,codex")
        t.equal(ids(Ordering.orderedProviders(five, order: "")), "openrouter,opencode,grok,codex,claude")
        t.equal(ids(Ordering.parseOrder("grok, bogus, grok, claude")), "grok,claude")
        t.equal(ids(Ordering.moveOrder("grok,claude,opencode,openrouter", id: .claude, delta: -1)), "claude,grok,opencode,openrouter")
        t.equal(ids(Ordering.moveOrder("claude,grok", id: .claude, delta: -1)), "claude,grok")
        t.equal(ids(Ordering.moveOrder("claude,grok", id: .claude, delta: 1)), "grok,claude")
        t.equal(ids(Ordering.moveOrder("claude,grok", id: .codex, delta: 1)), "claude,grok")

        let all = ProviderID.defaultOrder
        t.equal(ids(Ordering.reorderInsert("", visibleIDs: all, id: .claude, insertIndex: 0)), "claude,openrouter,opencode,grok,codex")
        t.equal(ids(Ordering.reorderInsert("", visibleIDs: all, id: .openrouter, insertIndex: 4)), "opencode,grok,codex,claude,openrouter")
        t.equal(ids(Ordering.reorderInsert("", visibleIDs: all, id: .grok, insertIndex: 2)), "openrouter,opencode,grok,codex,claude")
        t.equal(ids(Ordering.reorderInsert("openrouter,opencode,grok,codex,claude", visibleIDs: [.opencode, .claude], id: .claude, insertIndex: 0)),
                "openrouter,claude,opencode,grok,codex", "hidden agent keeps its slot")
        t.equal(ids(Ordering.reorderInsert("", visibleIDs: all, id: .claude, insertIndex: 99)), "openrouter,opencode,grok,codex,claude")
        t.equal(ids(Ordering.reorderInsert("", visibleIDs: all, id: .claude, insertIndex: -5)), "claude,openrouter,opencode,grok,codex")
        t.equal(ids(Ordering.reorderInsert("", visibleIDs: [.claude], id: .claude, insertIndex: 3)), "openrouter,opencode,grok,codex,claude", "single row")
        t.equal(ids(Ordering.reorderInsert("grok", visibleIDs: all, id: .codex, insertIndex: 99)), "grok,openrouter,opencode,claude,codex", "partial saved order completed")

        let shown = [provider(.opencode), provider(.claude), provider(.openrouter)]
        t.equal(ids(Ordering.shownProviders(shown, visibility: [:])), "opencode,claude,openrouter")
        t.equal(ids(Ordering.shownProviders(shown, visibility: [.claude: false])), "opencode,openrouter")
        t.equal(Ordering.shownProviders(shown, visibility: [.claude: false, .opencode: false, .openrouter: false]).count, 0)
        t.equal(Ordering.provider(shown, id: .claude)?.id, .claude)
        t.check(Ordering.provider(shown, id: .grok) == nil, "missing provider is nil")
    }

    // MARK: states

    static func states(_ t: TestRun) {
        t.equal(Meters.stateOf(12, warn: 70, critical: 90), .normal)
        t.equal(Meters.stateOf(70, warn: 70, critical: 90), .warning)
        t.equal(Meters.stateOf(90, warn: 70, critical: 90), .critical)
        t.equal(Meters.stateOf(nil), .normal)
        t.equal(Format.percentText(45.5), "45.5%")
        t.equal(Format.percentText(0), "0%")
        t.equal(Format.percentText(66.66666666666666), "66.7%")
        t.equal(Format.percentText(140), "100%")
        t.equal(Format.percentText(nil), "\u{2014}")

        // A window the source marks limited is critical whatever its percent.
        let codex = provider(.codex, limits: [limit("session", 80), limit("weekly", 40, limited: true)])
        let windows = Meters.windowsFor(codex)
        t.equal(windows.map(\.state), [.warning, .critical])
        t.equal(Meters.providerColor(codex), .critical)
        t.check(Meters.isAlarming(codex), "limited window alarms")
        let calm = provider(.codex, limits: [limit("session", 75), limit("weekly", 20)])
        t.equal(Meters.providerColor(calm), .warning)
        t.check(!Meters.isAlarming(calm), "warning does not alarm")
        t.equal(Meters.providerColor(provider(.claude)), .normal)

        let many = provider(.claude, limits: [limit("session", 1), limit("weekly", 95), limit("a", 3), limit("b", 4)])
        t.equal(Meters.barWindows(many).count, 3)
        t.equal(Meters.highest(Meters.windowsFor(many))?.key, "weekly")
        t.equal(Meters.highest(many.limits)?.key, "weekly")
        t.equal(Meters.highest([limit("x", 5), limit("y", 5)])?.key, "x", "ties keep the first")
        t.equal(Meters.highestMeterPercent([calm, many]), 95)
        t.equal(Summary.heroPercentText([calm]), "75%")
        t.equal(Summary.heroPercentText([]), "")
    }

    // MARK: formatting

    static func formatting(_ t: TestRun) {
        t.equal(Format.currency(1234.5), "$1,234.50")
        t.equal(Format.currency(nil), "\u{2014}")
        t.equal(Format.currency(-3), "-$3.00")
        t.equal(Format.currency(1234567.891), "$1,234,567.89")
        t.equal(Format.currency(0), "$0.00")
        t.equal(Format.count(1074715), "1.1M")
        t.equal(Format.count(135), "135")
        t.equal(Format.count(1200), "1.2K")
        t.equal(Format.count(1000), "1K")
        t.equal(Format.count(84000), "84K")
        t.equal(Format.count(320000), "320K")
        t.equal(Format.count(2_000_000_000), "2B")
        t.equal(Format.tokensText(84000), "84K tokens")
        t.equal(Format.tokensText(1_200_000), "1.2M tokens")
        t.equal(Format.tokensText(0), "")

        t.equal(Format.resetText(now + 3 * 3_600_000, now: now), "Resets in 3h 0m")
        t.equal(Format.resetText(now - 1, now: now), "Reset is due")
        t.equal(Format.resetText(now + 4 * day, now: now), "Resets in 4d 0h")
        t.equal(Format.resetText(now + (4 * 60 + 48) * 60_000, now: now), "Resets in 4h 48m")
        t.equal(Format.resetText(now + 10_000, now: now), "Resets in 1m")
        t.equal(Format.resetText(now + 12 * 60_000, now: now), "Resets in 12m")
        t.equal(Format.resetText(now + 47 * 3_600_000, now: now), "Resets in 47h 0m")
        t.equal(Format.resetText(0, now: now), "")

        t.equal(Format.updatedText(now - 5000, now: now), "Updated just now")
        t.equal(Format.updatedText(now - 42_000, now: now), "Updated 42s ago")
        t.equal(Format.updatedText(now - 5 * 60_000, now: now), "Updated 5m ago")
        t.equal(Format.updatedText(now - 2 * 3_600_000, now: now), "Updated 2h ago")
        t.equal(Format.updatedText(0, now: now), "")
        t.equal(Format.updatedAgo(now - 5 * 60_000, now: now), "5m ago")

        t.equal(Format.intervalName("weekly"), "Weekly")
        t.equal(Format.intervalName("day"), "Daily")
        t.equal(Format.intervalName("annual"), "Yearly")
        t.equal(Format.intervalName("none"), "No reset")
        t.equal(Format.intervalName(""), "Monthly")

        t.equal(Schedule.clampInt(4000, 60, 3600, fallback: 300), 3600)
        t.equal(Schedule.clampInt(nil, 0, 100, fallback: 70), 70)
        t.equal(Schedule.clampInt(.nan, 0, 100, fallback: 90), 90)
        t.equal(Schedule.clampInt(70.5, 0, 100, fallback: 0), 71)
    }

    // MARK: OpenRouter, management key (account-wide)

    static func openrouterAccount(_ t: TestRun) {
        let money = Money(label: Money.accountWideLabel, limit: nil, spend: 49.93, credits: 20.81, totalCredits: 535,
                          resetInterval: "monthly", resetsAt: cycleEnd)
        let limits = [
            Limit(key: "credits", label: "Credits", short: "cr", percent: 0, amount: 20.81),
            Limit(key: "key-aaaa1111", label: "hermes", short: "key", percent: 80, resetsAt: cycleEnd),
            Limit(key: "key-bbbb2222", label: "phoragent", short: "key", percent: 0, amount: 3.1),
            Limit(key: "key-cccc3333", label: "ci", short: "key", percent: 30, resetsAt: now + day / 2),
            Limit(key: "key-dddd4444", label: "spare", short: "key", percent: 0, amount: 0.5),
        ]
        var p = provider(.openrouter, tier: "Management key", limits: limits, money: money)
        p.status = "7 keys"

        // Panel: month first, Credits as a value row, keys in the collector's order.
        let windows = Meters.windowsFor(p)
        t.equal(windows.map(\.key), ["cycle", "credits", "key-aaaa1111", "key-bbbb2222", "key-cccc3333", "key-dddd4444"])
        t.equal(windows[0].detail, "All keys \u{00B7} this month")
        t.equal(Summary.windowValueText(windows[0]), "$49.93")
        let credits = windows[1]
        t.equal(credits.mode, .dollars, "Credits has no meter")
        t.equal(Summary.windowValueText(credits), "$20.81 left")
        t.equal(Summary.windowCaption(credits, now: now), "", "no lifetime totals")
        t.equal(credits.color, .normal)
        t.equal(Summary.windowValueText(windows[2]), "80%")
        t.equal(Summary.windowCaption(windows[2], now: now), "Resets in 15d 12h")
        t.equal(windows[3].mode, .dollars, "an unlimited key is a value row")
        t.equal(Summary.windowValueText(windows[3]), "$3.10 this month")
        t.equal(Summary.windowCaption(windows[3], now: now), "")
        t.equal(Summary.moneySummary(money), "")

        // The N cut (the openrouterKeyRows setting) keeps month and Credits.
        t.equal(Meters.windowsFor(p, keyRows: 2).map(\.key), ["cycle", "credits", "key-aaaa1111", "key-bbbb2222"])
        t.equal(Meters.windowsFor(p, keyRows: 0).map(\.key), ["cycle", "credits"])
        t.equal(Meters.windowsFor(p, keyRows: 99).count, 6)
        t.equal(Meters.windowsFor(p, keyRows: -1).map(\.key), ["cycle", "credits"], "negative → none")

        // Headline: never Credits; the highest key meter.
        t.equal(Meters.summaryWindow(windows)?.key, "key-aaaa1111")
        t.equal(Meters.highestMeterPercent([p]), 80)
        var onlyValues = p
        onlyValues.limits = [limits[0], limits[2]]
        t.equal(Meters.summaryWindow(Meters.windowsFor(onlyValues))?.mode, .dollars, "no meter → no headline percent")
        t.check(Meters.highestMeterPercent([onlyValues]) == nil, "credits never reach the hero")

        // Bar: the credits figure only, normal colour, no meters, in every style's text.
        t.check(Meters.isAccountWide(p), "account-wide")
        t.equal(Meters.creditsLeft(p), 20.81)
        t.equal(Meters.barMeters(p).count, 0)
        t.equal(Meters.barDollarsText(p), "$20.81")
        t.equal(Meters.barDollarsColor(p), .normal)
        t.equal(Summary.compactText(p), "$20.81 credits left \u{00B7} $49.93 this month")
        let tip = Summary.providerTooltip(p, now: now)
        t.equal(tip, "OpenRouter \u{00B7} Management key\n7 keys\n  $20.81 credits left \u{00B7} $49.93 this month")
        t.check(!tip.contains("535") && !Summary.compactText(p).contains("535"), "no lifetime totals")

        // No /credits (404): the month's spend in the bar.
        var noCredits = p
        noCredits.limits = Array(limits.dropFirst())
        t.check(Meters.creditsLeft(noCredits) == nil, "no credits")
        t.equal(Meters.barDollarsText(noCredits), "$49.93")
        t.equal(Summary.compactText(noCredits), "$49.93 this month")
        var idle = noCredits
        idle.money?.spend = 0
        t.equal(Meters.barDollarsText(idle), "", "nothing to show: mark only")

        // With a previous month observed the panel's money window is a meter; the bar still shows credits.
        let hist = CycleHistory(current: Cycle(key: "c", end: cycleEnd, spend: 49.93, lastObservedAt: now),
                                previous: Cycle(key: "p", end: cycleEnd - 30 * day, spend: 99.86, lastObservedAt: cycleEnd - 30 * day)).normalized()
        let metered = Meters.windowsFor(p, history: hist)
        t.equal(metered[0].mode, .meter)
        t.equal(metered[0].percent, 50)
        t.equal(Summary.windowCaption(metered[0], now: now), "$49.93 of $99.86 \u{00B7} Resets in 15d 12h")
        t.equal(Meters.barMeters(p, history: hist).count, 0)
        t.equal(Meters.barDollarsText(p, history: hist), "$20.81")
        var over = p
        over.money?.spend = 120
        t.equal(Meters.windowsFor(over, history: hist)[0].color, .yellow, "over the previous month")
        t.equal(Meters.providerColor(over, history: hist), .warning, "a key at 80% is not masked by the dollars window")
        t.equal(Meters.barDollarsColor(over, history: hist), .normal, "the bar figure stays normal")
        var hot = over
        hot.limits[1].percent = 95
        t.equal(Meters.providerColor(hot, history: hist), .critical, "over the previous month + a key at 95%")
        var calmOver = over
        calmOver.limits = [limits[0]]
        t.equal(Meters.providerColor(calmOver, history: hist), .yellow, "yellow when nothing else is elevated")

        // The cycle history keeps working for the account-wide money.
        let advanced = CycleHistory.empty.advanced(with: money, now: now)
        t.equal(advanced.current?.end, cycleEnd)
        t.equal(advanced.current?.spend, 49.93)

        // Value rows survive the cache; other providers and the per-key view are unaffected.
        let slim = UsageCache.slim(p)
        t.equal(slim.limits.map(\.amount), [20.81, nil, 3.1, nil, 0.5])
        t.check(Limit(key: "x", label: "x", short: "x", percent: 1, amount: .nan).amount == nil, "non-finite amount dropped")
        t.equal(Limit(key: "x", label: "x", short: "x", percent: 1, amount: -4).amount, 0, "negative amount clamped")
        let legacy = #"{"key":"weekly","label":"Weekly","short":"7d","percent":12,"resetsAt":0,"limited":false,"stale":false}"#
        let decoded = try? JSONDecoder().decode(Limit.self, from: Data(legacy.utf8))
        t.check(decoded != nil && decoded?.amount == nil, "an old cache entry decodes without amount")
        t.equal(Meters.periodPhrase("weekly"), "this week")
        t.equal(Meters.periodPhrase("daily"), "today")
        t.equal(Meters.periodPhrase(""), "this month")
        let perKey = provider(.openrouter, money: Money(label: "key \u{2026}abc", limit: nil, spend: 3, resetInterval: "monthly"))
        t.check(!Meters.isAccountWide(perKey), "per-key view")
        t.equal(Meters.windowsFor(perKey).map(\.key), ["cycle"], "per-key view unchanged")
        t.equal(Summary.compactText(perKey), "$3.00")
        t.equal(Meters.barDollarsText(perKey), "$3.00")
        let claude = provider(.claude, limits: [limit("session", 40)])
        t.equal(Meters.windowsFor(claude, keyRows: 0).count, 1, "keyRows only affects OpenRouter")
    }

    // MARK: OpenRouter

    static func openrouter(_ t: TestRun) {
        let limited = provider(.openrouter, money: Money(label: "key \u{2026}demo", limit: 20, spend: 10, credits: 30,
                                                        totalCredits: 50, resetInterval: "monthly", resetsAt: cycleEnd))
        guard let w = Meters.openrouterWindow(limited, history: .empty, warn: 70, critical: 90) else {
            return t.check(false, "limited window exists")
        }
        t.equal(w.mode, .meter)
        t.equal(w.percent, 50)
        t.equal(w.effectiveLimit, 20)
        t.equal(w.color, .normal)
        t.equal(w.detail, "Key limit")
        t.equal(w.credits, 30)
        t.check(w.meterVisible, "limited key with spend draws a meter")

        let unlimited = provider(.openrouter, money: Money(label: "key", limit: nil, spend: 8, resetInterval: "monthly", resetsAt: cycleEnd))
        let hist = CycleHistory(current: Cycle(key: "c", end: cycleEnd, spend: 8, lastObservedAt: now),
                                previous: Cycle(key: "p", end: cycleEnd - 30 * day, spend: 12, lastObservedAt: cycleEnd - 30 * day)).normalized()
        let base = Meters.openrouterWindow(unlimited, history: hist, warn: 70, critical: 90)!
        t.equal(base.mode, .meter)
        t.equal(base.effectiveLimit, 12)
        t.equal(base.percent, 66.66666666666666)
        t.equal(base.detail, "Cycle spend")
        t.equal(base.color, .normal)

        var overP = unlimited
        overP.money?.spend = 13
        let over = Meters.openrouterWindow(overP, history: hist, warn: 70, critical: 90)!
        t.equal(over.mode, .dollars)
        t.equal(over.color, .yellow)
        t.equal(over.state, .normal)
        t.check(over.over, "over the previous cycle")
        t.equal(Meters.barDollarsText(overP, history: hist), "$13.00")
        t.equal(Meters.barMeters(overP, history: hist).count, 0)
        t.equal(Meters.providerColor(overP, history: hist), .yellow)

        var warnP = unlimited
        warnP.money?.spend = 11
        t.equal(Meters.openrouterWindow(warnP, history: hist)?.color, .critical, "11 of 12 is 91.7%")

        // No baseline: dollars only.
        let noBase = Meters.openrouterWindow(unlimited, history: .empty)!
        t.equal(noBase.mode, .dollars)
        t.check(noBase.effectiveLimit == nil, "no effective limit without a baseline")
        t.equal(Meters.barDollarsText(unlimited), "$8.00")

        // Zero spend: the bar draws only the mark.
        var zeroLimited = limited
        zeroLimited.money?.spend = 0
        t.equal(Meters.barMeters(zeroLimited).count, 0)
        t.equal(Meters.barDollarsText(zeroLimited), "")
        var zeroUnlimited = unlimited
        zeroUnlimited.money?.spend = 0
        t.equal(Meters.barMeters(zeroUnlimited).count, 0)
        t.equal(Meters.barDollarsText(zeroUnlimited), "")
        t.equal(Meters.barMeters(limited).count, 1)

        t.check(Meters.openrouterWindow(provider(.openrouter)) == nil, "no money, no window")
        t.equal(Meters.windowsFor(provider(.openrouter)).count, 0)
        t.equal(Summary.moneySummary(limited.money!), "$30.00 credits left \u{00B7} $20.00 monthly limit")
        t.equal(Summary.moneySummary(unlimited.money!), "No key limit")
        t.equal(Summary.windowCaption(base, now: now), "$8.00 of $12.00 \u{00B7} Resets in 15d 12h")
        t.equal(Summary.windowCaption(over, now: now), "Resets in 15d 12h \u{00B7} over the previous cycle")
        t.equal(Summary.windowValueText(over), "$13.00")
        t.equal(Summary.windowValueText(base), "66.7%")
    }

    static func history(_ t: TestRun) {
        let money = { (spend: Double, resetsAt: Double) in
            Money(label: "key", limit: 20, spend: spend, resetInterval: "monthly", resetsAt: resetsAt)
        }
        let first = CycleHistory.empty.advanced(with: money(3, cycleEnd), now: now)
        t.equal(first.current?.end, cycleEnd)
        t.check(first.previous == nil, "first cycle has no previous")

        let same = first.advanced(with: money(5, cycleEnd), now: now + 1000)
        t.equal(same.current?.spend, 5)
        let lower = same.advanced(with: money(2, cycleEnd), now: now + 2000)
        t.equal(lower.current?.spend, 5, "same cycle keeps the larger spend")
        t.equal(lower.current?.lastObservedAt, now + 2000)

        var late = same
        late.current?.lastObservedAt = cycleEnd
        let observedLate = late.advanced(with: money(0, cycleEnd + 30 * day), now: cycleEnd + 1000)
        t.equal(observedLate.previous?.spend, 5)
        t.equal(observedLate.current?.end, cycleEnd + 30 * day)

        // Last seen a day before the reset: a missed cycle is not a baseline.
        var missed = same
        missed.current?.lastObservedAt = cycleEnd - day
        let skipped = missed.advanced(with: money(1, cycleEnd + 30 * day), now: cycleEnd + day)
        t.check(skipped.previous == nil, "cycle not observed near its end is dropped")
        t.equal(skipped.current?.spend, 1)

        // A fractional reset time is still one cycle, and keeps its baseline.
        let fractional = observedLate.advanced(with: money(2, cycleEnd + 30 * day + 0.4), now: cycleEnd + 2000)
            .advanced(with: money(3, cycleEnd + 30 * day + 0.4), now: cycleEnd + 3000)
        t.equal(fractional.current?.end, cycleEnd + 30 * day)
        t.equal(fractional.current?.spend, 3)
        t.equal(fractional.previous?.spend, 5, "baseline survives a fractional reset time")

        // An older cycle never replaces the current one; nil money changes nothing.
        t.equal(same.advanced(with: money(9, cycleEnd - 30 * day), now: now), same)
        t.equal(same.advanced(with: nil, now: now), same)
        t.equal(same.advanced(with: money(9, 0), now: now), same)

        // Normalisation drops a previous that ends after current, and a history without current.
        let odd = CycleHistory(current: Cycle(key: "", end: cycleEnd, spend: -4, lastObservedAt: now),
                               previous: Cycle(key: "p", end: cycleEnd + day, spend: 1, lastObservedAt: 0)).normalized()
        t.check(odd.previous == nil, "previous after current dropped")
        t.equal(odd.current?.spend, 0)
        t.equal(odd.current?.key, String(Int64(cycleEnd)), "missing key defaults to the end")
        t.equal(CycleHistory(current: nil, previous: Cycle(key: "p", end: cycleEnd, spend: 1, lastObservedAt: 0)).normalized(), .empty)
    }

    // MARK: cache

    static func cache(_ t: TestRun) {
        let list = [
            provider(.claude, limits: [limit("session", 12, cycleEnd)]),
            provider(.openrouter, money: Money(label: "key \u{2026}demo", limit: 20, spend: 4, resetInterval: "monthly", resetsAt: cycleEnd)),
        ]
        let hist = CycleHistory.empty.advanced(with: list[1].money, now: now)
        let raw = UsageCache(providers: list, history: hist, fetchedAt: now, attemptedAt: now, failures: 0, error: "").serialize()
        t.check(raw.count < 8000, "cache stays small (\(raw.count) bytes)")
        t.check(!raw.contains("Bearer"), "no key material")
        t.check(raw.hasSuffix("\n"), "trailing newline")
        guard let parsed = UsageCache.parse(raw, now: now) else { return t.check(false, "cache parses") }
        t.equal(parsed.providers.count, 2)
        t.equal(parsed.providers[1].money?.limit, 20)
        t.equal(parsed.providers, list)
        t.equal(parsed.history, hist)
        t.equal(parsed.fetchedAt, now)
        t.check(UsageCache.parse("{\"version\":99}", now: now) == nil, "other version rejected")
        t.check(UsageCache.parse("not json", now: now) == nil, "garbage rejected")
        t.check(UsageCache.parse("", now: now) == nil, "empty rejected")

        // Future timestamps, bad providers, markup and bad history are cleaned up.
        let messy = """
        {"version":1,"fetchedAt":\(Int64(now + 3_600_000)),"attemptedAt":\(Int64(now)),"failures":2.6,"error":"<b>x</b>",
         "data":{"providers":[{"id":"nope"},\(String(decoding: try! JSONEncoder().encode(list[0]), as: UTF8.self)),42]},
         "history":"junk"}
        """
        guard let cleaned = UsageCache.parse(messy, now: now) else { return t.check(false, "messy cache parses") }
        t.equal(cleaned.fetchedAt, 0, "future fetchedAt dropped")
        t.equal(cleaned.attemptedAt, now)
        t.equal(cleaned.failures, 3)
        t.equal(cleaned.error, "\u{2039}b\u{203A}x\u{2039}/b\u{203A}")
        t.equal(cleaned.providers.map(\.id), [.claude])
        t.equal(cleaned.history, .empty)

        var dirty = provider(.claude, tier: "<b>Max</b>", limits: (0..<9).map { limit("k\($0)", 1) })
        dirty.money = Money(limit: -1, spend: .nan)
        let slim = UsageCache.slim(dirty)
        t.equal(slim.tier, "\u{2039}b\u{203A}Max\u{2039}/b\u{203A}")
        t.equal(slim.limits.count, 9)
        t.equal(UsageCache.slim(provider(.claude, limits: (0..<20).map { limit("k\($0)", 1) })).limits.count, 12)
        t.check(slim.money?.limit == nil && slim.money?.spend == 0, "money numbers sanitised")
        t.check(!UsageCache(providers: [dirty]).serialize().isEmpty, "non-finite numbers still serialise")

        // File I/O: 0700 directory (forced even if it existed), atomic write, round trip.
        let home = Fixtures.tempHome("logic-cache")
        let dir = home.appendingPathComponent("Caches/agentic")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        let url = dir.appendingPathComponent("usage.json")
        do {
            try UsageCache(providers: list, history: hist, fetchedAt: now, attemptedAt: now).write(to: url)
            let perms = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)??.intValue
            t.equal(perms, 0o700, "cache dir is 0700")
            let filePerms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
            t.equal(filePerms, 0o600, "cache file is 0600")
            t.equal(UsageCache.read(from: url, now: now)?.providers, list)
        } catch {
            t.check(false, "cache write failed: \(error)")
        }
        t.check(UsageCache.read(from: home.appendingPathComponent("missing.json"), now: now) == nil, "missing file is nil")
        try? FileManager.default.removeItem(at: home)
        t.check(UsageCache.defaultURL(home: URL(fileURLWithPath: "/h")).path == "/h/Library/Caches/com.crueber.agentic-apple/usage.json", "default cache path")
    }

    // MARK: bar text and tooltip

    static func text(_ t: TestRun) {
        let grok = provider(.grok, tier: "SuperGrok",
                            limits: [limit("weekly", 2, cycleEnd), limit("bot", 42, cycleEnd, short: "bot", stale: true)])
        t.equal(Summary.compactText(grok, history: .empty, warn: 70, critical: 90), "7d 2% \u{00B7} bot \u{2014}")
        let tip = Summary.providerTooltip(grok, history: .empty, now: now, warn: 70, critical: 90)
        t.check(tip.hasPrefix("Grok \u{00B7} SuperGrok"), "tooltip head: \(tip)")
        t.check(tip.contains("stale"), "tooltip marks stale")
        t.equal(tip, "Grok \u{00B7} SuperGrok\n  weekly: 2% \u{00B7} Resets in 15d 12h\n  bot: 42% \u{00B7} Resets in 15d 12h \u{00B7} stale")

        var failing = provider(.claude, tier: "", limits: [])
        failing.status = "Sign-in expired"
        failing.error = "token expired"
        t.equal(Summary.compactText(failing), "Sign-in expired")
        t.equal(Summary.providerTooltip(failing, now: now), "Claude\nSign-in expired\ntoken expired")
        t.equal(Summary.tooltip([], now: now), "No AI agents found")
        t.equal(Summary.tooltip([failing, failing], now: now).components(separatedBy: "\n\n").count, 2)

        let money = Money(label: "key", limit: nil, spend: 4.2, resetsAt: cycleEnd)
        t.equal(Summary.compactText(provider(.openrouter, money: money)), "$4.20")
        let limitedMoney = Money(label: "key", limit: 20, spend: 5, resetsAt: cycleEnd)
        t.equal(Summary.compactText(provider(.openrouter, money: limitedMoney)), "25%")
        t.equal(Summary.providerTooltip(provider(.openrouter, tier: "", money: limitedMoney), now: now),
                "OpenRouter\n  Key limit: 25% of $20.00 \u{00B7} Resets in 15d 12h")

        var active = provider(.claude)
        active.activity = Activity(period: "today", prompts: 4, tokens: 320_000)
        t.equal(Summary.activityText(active), "Today \u{00B7} 4 prompts \u{00B7} 320K tokens")
        active.activity = Activity(period: "week", prompts: 0, tokens: 1_200_000)
        t.equal(Summary.activityText(active), "This week \u{00B7} 1.2M tokens")
        active.activity = .empty
        t.equal(Summary.activityText(active), "")
        t.equal(Summary.budgetValueText(Budget(label: "Monthly", spend: 3, limit: 10, percent: 30)), "$3.00 / $10.00")
    }

    // MARK: schedule

    static func schedule(_ t: TestRun) {
        let minute: Double = 60_000
        // Backoff: 1, 2, 4, 8, then capped at 10 minutes, counted from the last attempt.
        let expected: [Double] = [1, 2, 4, 8, 10, 10]
        for (i, m) in expected.enumerated() {
            t.equal(Schedule.autoDelayMs(fetchedAt: 0, attemptedAt: now, failures: i + 1, refreshMs: 300_000, now: now),
                    m * minute, "backoff after \(i + 1) failures")
        }
        t.equal(Schedule.autoDelayMs(fetchedAt: 0, attemptedAt: now - 30_000, failures: 1, refreshMs: 300_000, now: now), 30_000)
        t.equal(Schedule.autoDelayMs(fetchedAt: 0, attemptedAt: now - 10 * minute, failures: 1, refreshMs: 300_000, now: now), 250)
        t.equal(Schedule.autoDelayMs(fetchedAt: 0, attemptedAt: 0, failures: 3, refreshMs: 300_000, now: now), 4 * minute)
        // Healthy: the interval from the last fetch or attempt.
        t.equal(Schedule.autoDelayMs(fetchedAt: 0, attemptedAt: 0, failures: 0, refreshMs: 300_000, now: now), 250, "never fetched")
        t.equal(Schedule.autoDelayMs(fetchedAt: now - minute, attemptedAt: 0, failures: 0, refreshMs: 300_000, now: now), 4 * minute)
        t.equal(Schedule.autoDelayMs(fetchedAt: now - 2 * minute, attemptedAt: now - minute, failures: 0, refreshMs: 300_000, now: now), 4 * minute)
        t.equal(Schedule.autoDelayMs(fetchedAt: now - 10 * minute, attemptedAt: 0, failures: 0, refreshMs: 300_000, now: now), 250)
        t.equal(Schedule.autoDelayMs(fetchedAt: now, attemptedAt: 0, failures: 0, refreshMs: 1000, now: now), minute, "interval floor 60 s")
        t.equal(Schedule.autoDelayMs(fetchedAt: now, attemptedAt: 0, failures: 0, refreshMs: 0, now: now), 5 * minute, "default interval")

        // Manual refresh at most every 30 s; automatic at most every 60 s.
        t.check(!Schedule.canFetch(lastAttemptMs: now - 29_000, now: now, manual: true), "manual within 30 s throttled")
        t.check(Schedule.canFetch(lastAttemptMs: now - 30_000, now: now, manual: true), "manual after 30 s allowed")
        t.check(!Schedule.canFetch(lastAttemptMs: now - 45_000, now: now, manual: false), "auto within 60 s throttled")
        t.check(Schedule.canFetch(lastAttemptMs: 0, now: now, manual: true), "first fetch allowed")
        t.equal(Schedule.nextFailures(0), 1)
        t.equal(Schedule.nextFailures(20), 20)
    }

    // MARK: merge

    static func merge(_ t: TestRun) {
        var good = provider(.claude, limits: [limit("session", 40, cycleEnd)])
        good.readAt = now - 60_000
        good.source = "oauth"
        let otherGood = provider(.codex, limits: [limit("weekly", 10)])

        var failed = provider(.claude, tier: "", limits: [])
        failed.error = "HTTP 500"
        failed.source = "none"
        let freshCodex = provider(.codex, limits: [limit("weekly", 12)])
        let merged = ProviderMerge.merge(previous: [good, otherGood], fresh: [failed, freshCodex])
        t.equal(merged.map(\.id), [.claude, .codex])
        t.equal(merged[0].limits, good.limits, "failed provider keeps its numbers")
        t.equal(merged[0].error, "HTTP 500", "and gains the error")
        t.equal(merged[0].tier, "Max 5x", "empty fresh tier keeps the old one")
        t.equal(merged[0].source, "oauth")
        t.equal(merged[0].readAt, now - 60_000)
        t.check(merged[0].available, "still available")
        t.equal(merged[1].limits.first?.percent, 12, "healthy provider takes fresh numbers")

        // Fresh numbers alongside an error win; no previous good entry passes through.
        var partial = failed
        partial.limits = [limit("session", 55)]
        t.equal(ProviderMerge.merge(previous: [good], fresh: [partial])[0].limits.first?.percent, 55)
        t.equal(ProviderMerge.merge(previous: [], fresh: [failed])[0], failed)
        var unavailable = good
        unavailable.available = false
        t.equal(ProviderMerge.merge(previous: [unavailable], fresh: [failed])[0], failed)
        // A clean fresh entry replaces the old one entirely.
        t.equal(ProviderMerge.merge(previous: [good], fresh: [otherGood]), [otherGood])
    }

    // MARK: paused sign-in keeps stale limits

    static func mergePaused(_ t: TestRun) {
        let good = provider(.claude, limits: [limit("session", 18, now + day), limit("weekly", 62, now + 5 * day)])
        var expired = provider(.claude, tier: "", limits: [])
        expired.status = "Sign-in expired"
        expired.hint = "run claude auth login"
        let merged = ProviderMerge.merge(previous: [good], fresh: [expired])[0]
        t.equal(merged.limits.map(\.percent), [18, 62], "expired sign-in keeps the previous limits")
        t.check(merged.limits.allSatisfy(\.stale), "kept limits are marked stale")
        t.equal(merged.status, "Sign-in expired")
        t.equal(merged.hint, "run claude auth login")
        t.equal(merged.tier, "Max 5x", "empty fresh tier keeps the old one")
        t.equal(merged.error, "")
        t.check(merged.available, "still available")

        var paused = expired
        paused.status = "Limits paused"
        paused.tier = "Pro"
        let p2 = ProviderMerge.merge(previous: [good], fresh: [paused])[0]
        t.equal(p2.tier, "Pro")
        t.check(p2.limits.count == 2 && p2.limits.allSatisfy(\.stale), "limits paused keeps stale limits")

        // Chained: a second expired read keeps the stale limits (previous is now the merged one).
        let p3 = ProviderMerge.merge(previous: [merged], fresh: [expired])[0]
        t.equal(p3.limits.count, 2)
        // Other statuses, no previous, previous without limits: fresh passes through.
        var waiting = expired
        waiting.status = "Waiting for auth"
        t.equal(ProviderMerge.merge(previous: [good], fresh: [waiting])[0], waiting)
        t.equal(ProviderMerge.merge(previous: [], fresh: [expired])[0], expired)
        t.equal(ProviderMerge.merge(previous: [provider(.claude)], fresh: [expired])[0], expired)
        // Fresh limits after sign-in returns replace the stale ones.
        let back = provider(.claude, limits: [limit("session", 3)])
        t.equal(ProviderMerge.merge(previous: [merged], fresh: [back])[0], back)
        // intervalName: OpenRouter sends "daily" (no "day" substring).
        t.equal(Format.intervalName("daily"), "Daily", "daily")
        t.equal(Format.intervalName("day"), "Daily")
        t.equal(Format.intervalName("weekly"), "Weekly")
        t.equal(Format.intervalName("monthly"), "Monthly")
    }
}

