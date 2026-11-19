import Foundation
import AgenticCore

/// 1.1.1: daily key limits, history from clean reads only, history per scope.
extension OpenRouterTests {
    static func historyFixes(_ t: TestRun) {
        // A per-key daily limit reads usage_daily (not the monthly figure).
        let daily = OpenRouterCollector.pickMoney(doc(
            #"{"data":{"label":"sk-or-v1-abc...demo","limit":5,"limit_reset":"daily","usage_daily":1.25,"usage_monthly":40,"usage":90}}"#))
        t.equal(daily?.spend, 1.25, "daily limit reads usage_daily")
        let weekly = OpenRouterCollector.pickMoney(doc(
            #"{"data":{"label":"k","limit":5,"limit_reset":"weekly","usage_weekly":3,"usage_monthly":40}}"#))
        t.equal(weekly?.spend, 3, "weekly limit reads usage_weekly")
        let monthly = OpenRouterCollector.pickMoney(doc(
            #"{"data":{"label":"k","limit":5,"limit_reset":"monthly","usage_daily":1,"usage_monthly":40}}"#))
        t.equal(monthly?.spend, 40, "monthly limit reads usage_monthly")

        let oct1 = LogicTests.utc(2026, 10, 1), nov1 = LogicTests.utc(2026, 11, 1), dec1 = LogicTests.utc(2026, 12, 1)
        let account = { (spend: Double, end: Double) in
            Money(label: Money.accountWideLabel, spend: spend, resetInterval: "monthly", resetsAt: end) }
        let ok = { (m: Money) in Provider(id: .openrouter, available: true, money: m) }

        var h = CycleHistory.empty
        h = h.advanced(withFresh: ok(account(50, nov1)), now: nov1 - 3_600_000)
        t.equal(h.scope, Money.accountWideLabel, "scope recorded")

        // A failed read carrying last cycle's numbers (as the merge would) never advances.
        var failed = ok(account(50, dec1))
        failed.error = "OpenRouter did not answer"
        t.equal(h.advanced(withFresh: failed, now: nov1 + 3_600_000), h, "an errored read leaves history alone")
        t.equal(h.advanced(withFresh: nil, now: nov1 + 3_600_000), h, "no OpenRouter read leaves history alone")
        var gone = ok(account(50, dec1)); gone.available = false
        t.equal(h.advanced(withFresh: gone, now: nov1 + 3_600_000), h, "unavailable read leaves history alone")
        t.equal(h.advanced(withFresh: Provider(id: .openrouter, available: true), now: nov1 + 3_600_000), h,
                "a read without money leaves history alone")

        // A clean read moves to the new cycle as before.
        let moved = h.advanced(withFresh: ok(account(2, dec1)), now: nov1 + 3_600_000)
        t.equal(moved.current?.spend, 2, "clean read starts the new cycle")
        t.equal(moved.previous?.spend, 50, "and keeps the completed one")

        // Switching scope (account-wide ↔ a key, or another key) starts a new series.
        let perKey = Money(label: "key \u{2026}demo", spend: 7, resetInterval: "monthly", resetsAt: dec1)
        let switched = moved.advanced(withFresh: ok(perKey), now: nov1 + 7_200_000)
        t.equal(switched.scope, "key \u{2026}demo", "new scope")
        t.check(switched.completed.isEmpty, "no account history under a key")
        t.equal(switched.current?.spend, 7, "the key's own spend")
        let back = switched.advanced(withFresh: ok(account(2, dec1)), now: nov1 + 10_800_000)
        t.check(back.completed.isEmpty && back.current?.spend == 2, "and back: a fresh account series")

        // A 1.1.0 cache (no scope) adopts the next scope and keeps its cycles.
        let legacy = #"{"current":{"key":"c","end":\#(Int(nov1)),"spend":50,"lastObservedAt":\#(Int(nov1 - 3_600_000))},"completed":[{"key":"p","end":\#(Int(oct1)),"spend":40,"lastObservedAt":\#(Int(oct1 - 3_600_000))}]}"#
        let old = try? JSONDecoder().decode(CycleHistory.self, from: Data(legacy.utf8))
        t.check(old != nil && old?.scope == nil, "1.1.0 history reads with no scope")
        let adopted = old?.advanced(withFresh: ok(account(3, dec1)), now: nov1 + 3_600_000)
        t.equal(adopted?.scope, Money.accountWideLabel, "adopts the scope")
        t.equal(adopted?.completed.map(\.spend), [50, 40], "keeps its cycles")

        // Scope survives encoding and normalisation.
        let data = try? JSONEncoder().encode(moved)
        let round = data.flatMap { try? JSONDecoder().decode(CycleHistory.self, from: $0) }
        t.equal(round, moved, "round trip with scope")
        t.equal(moved.normalized().scope, Money.accountWideLabel, "normalized keeps scope")
    }
}
