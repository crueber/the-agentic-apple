import Foundation
import AgenticCore

/// `openrouterAverageMonths`: the account-wide usage meter's N (0 = off).
extension OpenRouterTests {
    static func averageMonths(_ t: TestRun) async {
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { Date(timeIntervalSince1970: LogicTests.utc(y, m, d, h) / 1000) }
        let u = { (y: Int, m: Int, d: Int) in LogicTests.utc(y, m, d) }
        func body(_ start: String, _ end: String) -> String {
            #"{"metrics":["cost"],"granularity":"month","time_range":{"start":""# + start + #"T00:00:00Z","end":""# + end + #"T00:00:00Z"}}"#
        }

        // Query ranges: the N full months before this one, across year boundaries.
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2026, 11, 19), months: 1), body("2026-10-01", "2026-11-01"))
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2026, 11, 19), months: 3), body("2026-08-01", "2026-11-01"))
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2027, 1, 2), months: 1), body("2026-12-01", "2027-01-01"))
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2027, 2, 10), months: 3), body("2026-11-01", "2027-02-01"))
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2026, 11, 19), months: 12), body("2025-11-01", "2026-11-01"))
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2027, 1, 1), months: 12), body("2026-01-01", "2027-01-01"))
        t.check(OpenRouterCollector.queryBody(metric: "cost", now: at(2026, 11, 19), months: 0) == nil, "0 = off: no query")
        t.check(OpenRouterCollector.queryBody(metric: "cost", now: at(2026, 11, 19), months: 13) == nil, "beyond 12")
        t.equal(OpenRouterCollector.rangeLabel(at(2026, 10, 1), months: 1), "Oct")
        t.equal(OpenRouterCollector.rangeLabel(at(2026, 8, 1), months: 3), "Aug\u{2013}Oct")
        t.equal(OpenRouterCollector.rangeLabel(at(2025, 11, 1), months: 12), "Nov\u{2013}Oct")
        t.equal(OpenRouterCollector.rangeLabel(at(2026, 11, 1), months: 3), "Nov\u{2013}Jan")

        // Parsing with N rows, same strict rules.
        let s3 = at(2026, 8, 1), e3 = at(2026, 11, 1)
        func parse3(_ json: String) -> Double? {
            OpenRouterCollector.parseTotal(doc(json), metric: "cost", start: s3, end: e3, months: 3)
        }
        t.equal(parse3(#"{"data":{"data":[{"d":"2026-08-01","cost":30},{"d":"2026-09-01","cost":60},{"d":"2026-10-01","cost":90}]}}"#), 180)
        t.equal(parse3(#"{"data":{"data":[{"cost":1},{"cost":2},{"cost":3},{"cost":4}]}}"#), nil, "more rows than months")
        t.equal(parse3(#"{"data":{"data":[{"d":"2026-09-01","cost":60},{"d":"2026-10-01","cost":90}],"metadata":{"row_count":2,"truncated":false}}}"#),
                150, "a complete answer with a month missing: that month is 0")
        t.equal(parse3(#"{"data":{"data":[{"cost":60},{"cost":90}]}}"#), nil, "two of three rows, not clearly complete")
        t.equal(parse3(#"{"data":{"data":[{"d":"2026-07-01","cost":1},{"cost":2},{"cost":3}]}}"#), nil, "outside the range")
        t.equal(OpenRouterCollector.parseTotal(doc(#"{"data":{"data":[{"d":"2026-10","cost":42}]}}"#), metric: "cost",
                                               start: at(2026, 10, 1), end: at(2026, 11, 1), months: 1), 42, "N = 1")

        // Collector: off → no analytics at all and no meter; N changes are keyed and refetch once.
        let creditsOK = #"{"data":{"total_credits":535,"total_usage":514.19}}"#
        let keys = keysDoc([keyJSON(hash: "aaaa1111", name: "hermes", monthly: 49.93)])
        let three = #"{"data":{"data":[{"date":"2026-08-01","cost":30},{"date":"2026-09-01","cost":60},{"date":"2026-10-01","cost":90}]}}"#
        let two = #"{"data":{"data":[{"date":"2026-09-01","cost":60},{"date":"2026-10-01","cost":62.4}]}}"#
        let routes: [String: OpenRouterStubHTTP.Reply] = [
            keysPage0: .json(200, keys), creditsURL: .json(200, creditsOK),
            metaURL: .json(200, metaDoc([metric("cost", label: "Cost")])),
        ]
        func ctx(_ http: OpenRouterStubHTTP, months: Int, cached: MonthlyBaseline? = nil) -> CollectorContext {
            var c = mgmtContext(home: Fixtures.tempHome("or-avg"), http: http)
            c.openrouterAverageMonths = months
            c.openrouterBaseline = cached
            return c
        }
        do {
            let memo = AnalyticsMemo()
            let c = OpenRouterCollector(managementKeyReader: { _ in mgmtKey }, analytics: memo)
            let off = OpenRouterStubHTTP(routes.merging(["POST " + queryURL: .json(200, two)]) { $1 })
            let p0 = await c.collect(ctx(off, months: 0))
            t.equal(off.calls.map(\.url), [keysPage0, creditsURL], "usage meter off: no analytics request")
            t.check(p0.money?.baseline == nil, "no baseline")
            t.equal(p0.money?.averageMonths, 0)
            // Even with history, off means no meter anywhere.
            let hist = CycleHistory(current: Cycle(key: "c", end: u(2026, 12, 1), spend: 49.93, lastObservedAt: u(2026, 11, 19)),
                                    completed: [Cycle(key: "p", end: u(2026, 11, 1), spend: 80, lastObservedAt: u(2026, 11, 1))])
            let w0 = Meters.windowsFor(p0, history: hist)[0]
            t.equal(w0.mode, .dollars, "off → dollars")
            t.equal(Summary.windowValueText(w0), "$49.93")
            t.equal(Summary.windowCaption(w0, now: mgmtNow.timeIntervalSince1970 * 1000), "Resets in 11d 12h", "no average caption")
            t.equal(Meters.barMeters(p0, history: hist).count, 0, "bar: mark + credits only")
            t.equal(Meters.barDollarsText(p0, history: hist), "$20.81")
            t.equal(Summary.accountWideBarText(p0, history: hist), "$20.81")

            // N = 3: one query for Aug–Oct, average = total / 3.
            let http3 = OpenRouterStubHTTP(routes.merging(["POST " + queryURL: .json(200, three)]) { $1 })
            let p3 = await c.collect(ctx(http3, months: 3))
            t.equal(p3.money?.baseline, MonthlyBaseline(month: "2026-11", average: 60, months: 3, label: "Aug\u{2013}Oct"))
            t.equal(http3.bodies, [body("2026-08-01", "2026-11-01")])
            let w3 = Meters.windowsFor(p3)[0]
            t.equal(Summary.windowCaption(w3, now: mgmtNow.timeIntervalSince1970 * 1000), "$49.93 of $60.00 avg (Aug\u{2013}Oct) \u{00B7} Resets in 11d 12h")
            var over3 = p3
            over3.money?.spend = 70
            t.check(Summary.windowCaption(Meters.windowsFor(over3)[0], now: 0).hasSuffix("over the 3-month average"), "3-month over note")

            // Same N again: no new query. Change N to 2: one new query (keyed by month and N).
            _ = await c.collect(ctx(http3, months: 3))
            t.equal(http3.bodies.count, 1, "cached for (month, 3)")
            let http2 = OpenRouterStubHTTP(routes.merging(["POST " + queryURL: .json(200, two)]) { $1 })
            let p2 = await c.collect(ctx(http2, months: 2, cached: p3.money?.baseline))
            t.equal(http2.bodies, [body("2026-09-01", "2026-11-01")], "N changed → refetched once")
            t.equal(p2.money?.baseline?.months, 2)
            t.equal(p2.money?.baseline?.label, "Sep\u{2013}Oct")
            _ = await c.collect(ctx(http2, months: 2, cached: p2.money?.baseline))
            t.equal(http2.bodies.count, 1, "cached for (month, 2)")
            // A cached baseline for another N is not shown either.
            var mismatch = p2
            mismatch.money?.averageMonths = 3
            t.equal(Meters.windowsFor(mismatch)[0].mode, .dollars, "baseline for N=2 isn't used for N=3")

            // N = 1: "(Oct)", "over last month".
            let one = OpenRouterStubHTTP(routes.merging(["POST " + queryURL: .json(200, #"{"data":{"data":[{"date":"2026-10-01","cost":40}]}}"#)]) { $1 })
            let p1 = await c.collect(ctx(one, months: 1))
            t.equal(one.bodies, [body("2026-10-01", "2026-11-01")])
            let w1 = Meters.windowsFor(p1)[0]
            t.equal(Summary.windowCaption(w1, now: mgmtNow.timeIntervalSince1970 * 1000), "$49.93 of $40.00 (Oct) \u{00B7} Resets in 11d 12h \u{00B7} over last month")
            t.equal(Summary.windowValueText(w1), "124.8%")

            // N = 12 across the year boundary.
            let twelve = OpenRouterStubHTTP(routes.merging(["POST " + queryURL: .json(200, #"{"data":{"data":[],"metadata":{"row_count":0,"truncated":false}}}"#)]) { $1 })
            var c12 = ctx(twelve, months: 12)
            c12.now = at(2027, 1, 5)
            _ = await c.collect(c12)
            t.equal(twelve.bodies, [body("2026-01-01", "2027-01-01")])
        }

        // History: migration of 1.0/early-1.1 caches, up to twelve cycles, fewer than N.
        do {
            let legacy = #"{"current":{"key":"c","end":\#(u(2026, 12, 1)),"spend":3,"lastObservedAt":1},"previous":{"key":"p","end":\#(u(2026, 11, 1)),"spend":60,"lastObservedAt":1},"older":{"key":"o","end":\#(u(2026, 10, 1)),"spend":50,"lastObservedAt":1}}"#
            let migrated = try? JSONDecoder().decode(CycleHistory.self, from: Data(legacy.utf8))
            t.equal(migrated?.completed.map(\.spend), [60, 50], "previous + older → completed")
            t.equal(migrated?.previous?.spend, 60)
            let encoded = String(decoding: (try? JSONEncoder().encode(migrated!)) ?? Data(), as: UTF8.self)
            t.check(encoded.contains("\"completed\"") && encoded.contains("\"previous\""), "writes the list (and previous for 1.0)")
            let roundTrip = try? JSONDecoder().decode(CycleHistory.self, from: Data(encoded.utf8))
            t.equal(roundTrip, migrated, "round trip")

            var h = CycleHistory.empty
            for i in 0..<15 {
                let end = LogicTests.utc(2026 + (i + 1) / 12, ((i + 1) % 12) + 1, 1)
                h = h.advanced(with: Money(spend: Double(i + 1), resetsAt: end), now: end - 3_600_000)
            }
            t.equal(h.completed.count, 12, "at most twelve completed cycles")
            t.equal(h.completed.first?.spend, 14, "most recent first")

            let money = { (n: Int?) in Money(label: Money.accountWideLabel, spend: 49.93, resetInterval: "monthly",
                                             resetsAt: u(2026, 12, 1), averageMonths: n) }
            let cur = Cycle(key: "c", end: u(2026, 12, 1), spend: 49.93, lastObservedAt: u(2026, 11, 19))
            let hist3 = CycleHistory(current: cur, completed: [
                Cycle(key: "oct", end: u(2026, 11, 1), spend: 90, lastObservedAt: u(2026, 11, 1)),
                Cycle(key: "sep", end: u(2026, 10, 1), spend: 60, lastObservedAt: u(2026, 10, 1)),
                Cycle(key: "aug", end: u(2026, 9, 1), spend: 30, lastObservedAt: u(2026, 9, 1)),
            ])
            func base(_ n: Int?, _ hist: CycleHistory = hist3) -> (Double, Int, String)? {
                Meters.accountBaseline(money(n), history: hist).map { ($0.average, $0.months, $0.text) }
            }
            t.check(base(0) == nil, "off")
            t.check(base(1).map { $0 == (90, 1, "(Oct)") } == true, "N = 1 → last month")
            t.check(base(nil).map { $0 == (75, 2, "avg (Sep\u{2013}Oct)") } == true, "nil (old cache) = 2")
            t.check(base(3).map { $0 == (60, 3, "avg (Aug\u{2013}Oct)") } == true, "N = 3")
            t.check(base(6).map { $0 == (60, 3, "avg (3 of 6 months)") } == true, "fewer known than asked: \(String(describing: base(6)))")
            let only1 = CycleHistory(current: cur, completed: [hist3.completed[0]])
            t.check(base(2, only1).map { $0 == (90, 1, "avg (1 of 2 months)") } == true, "one of two")
            var overMoney = money(6)
            overMoney.spend = 61
            let w = Meters.windowsFor(Provider(id: .openrouter, available: true, money: overMoney), history: hist3)[0]
            t.equal(w.overNote, "over the 3-month average", "the months actually averaged")
            // Per-key view: unaffected by N, previous cycle only.
            let perKey = Money(label: "key", spend: 8, resetInterval: "monthly", resetsAt: u(2026, 12, 1), averageMonths: 0)
            let pk = Meters.openrouterWindow(Provider(id: .openrouter, available: true, money: perKey), history: hist3)!
            t.equal(pk.effectiveLimit, 90, "per-key ignores the setting")
            t.equal(pk.mode, .meter)
        }
    }
}
