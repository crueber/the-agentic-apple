import Foundation
import AgenticCore

/// The management key's Keychain protocol (a fake `security`, never the real
/// one) and the analytics baseline (stubbed HTTP, never the network).
extension OpenRouterTests {
    /// Records every `security` call: argv and stdin.
    final class FakeSecurity: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(args: [String], stdin: String)] = []
        var answer: ([String]) -> CommandResult

        init(answer: @escaping ([String]) -> CommandResult = { _ in CommandResult(status: 0) }) { self.answer = answer }

        var tool: KeychainTool {
            KeychainTool { [self] args, input in
                lock.lock()
                calls.append((args, input.map { String(decoding: $0, as: UTF8.self) } ?? ""))
                let a = answer
                lock.unlock()
                return a(args)
            }
        }
        var recorded: [(args: [String], stdin: String)] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    static func keychain(_ t: TestRun) {
        let svc = "com.crueber.agentic-apple.openrouter-management-key"

        // Save: one `security -i`, both commands on stdin, the key never in argv.
        do {
            let fake = FakeSecurity()
            t.check(fake.tool.save("  \(mgmtKey)\n") == nil, "saved")
            let calls = fake.recorded
            t.equal(calls.count, 1)
            t.equal(calls.first?.args, ["-i"], "interactive mode, nothing else on the command line")
            t.equal(calls.first?.stdin,
                    "delete-generic-password -s \(svc) -a default\n"
                    + "add-generic-password -U -s \(svc) -a default -l \"The Agentic Apple \u{2014} OpenRouter management key\" -w \(mgmtKey)\n",
                    "delete, then add with the key as one token; EOF ends the session")
            t.check(calls.allSatisfy { !$0.args.joined(separator: " ").contains(mgmtKey) }, "key never in argv")

            // `security -i` exits with the last command's status: the add.
            let refused = FakeSecurity(answer: { _ in CommandResult(status: 45) })
            t.equal(refused.tool.save(mgmtKey), "The Keychain refused to save the key (security exit 45)")
            let stuck = FakeSecurity(answer: { _ in CommandResult(status: -1, timedOut: true) })
            t.equal(stuck.tool.save(mgmtKey), "The Keychain didn't answer; try again")

            // Anything `security -i` would split, unquote or unescape is refused before it runs.
            let none = FakeSecurity()
            for bad in ["sk-or-v1-abc def ghi jklmnop", "sk-or-v1-\"quoted\"-0000000", "sk-or-v1-back\\slash-000000",
                        "sk-or-v1-'single'-00000000", "sk-or-v1-semi;colon-0000000", "sk-or-v1-ünïcode-000000000", "short"] {
                t.check(none.tool.save(bad) != nil, "rejected: \(bad.count) chars")
                t.check(KeychainTool.saveScript(bad) == nil, "no script for a bad key")
            }
            t.equal(none.recorded.count, 0, "a bad key never reaches security")
            t.check(KeychainTool.saveScript("sk-or-v1-Ab0_.~+/=:-0123456789") != nil, "the allowed alphabet")
        }

        // Remove, isSaved, read: argv only, never -w except for the read.
        do {
            let fake = FakeSecurity()
            t.check(fake.tool.remove() == nil, "removed")
            t.check(fake.tool.isSaved(), "found")
            t.equal(fake.recorded.map(\.args), [
                ["delete-generic-password", "-s", svc, "-a", "default"],
                ["find-generic-password", "-s", svc, "-a", "default"],
            ], "attributes only for isSaved")
            let gone = FakeSecurity(answer: { _ in CommandResult(status: 44) })
            t.check(gone.tool.remove() == nil, "nothing to remove is fine")
            t.check(!gone.tool.isSaved(), "not saved")
            t.equal(gone.tool.read(), .absent, "exit 44 = not found")
            let denied = FakeSecurity(answer: { _ in CommandResult(status: 51) })
            t.equal(denied.tool.read(), .denied)
            t.check(denied.tool.remove() != nil, "a refused delete is reported")
            let timeout = FakeSecurity(answer: { _ in CommandResult(status: -1, timedOut: true) })
            t.equal(timeout.tool.read(), .unavailable)
            let ok = FakeSecurity(answer: { _ in CommandResult(status: 0, stdout: Data("\(mgmtKey)\n".utf8)) })
            t.equal(ok.tool.read(), .key(mgmtKey))
            t.equal(ok.recorded.last?.args, ["find-generic-password", "-s", svc, "-a", "default", "-w"])
            let junk = FakeSecurity(answer: { _ in CommandResult(status: 0, stdout: Data("not a key at all".utf8)) })
            t.equal(junk.tool.read(), .absent, "a malformed item is no key")
        }

        // Read once per process; Save/Remove replace the memo; denied is remembered.
        do {
            let fake = FakeSecurity(answer: { _ in CommandResult(status: 0, stdout: Data(mgmtKey.utf8)) })
            let memo = ManagementKeyMemo()
            let reader = OpenRouterCollector.defaultManagementKeyReader(memo: memo, tool: fake.tool)
            let ctx = CollectorContext(home: Fixtures.tempHome("or-memo"), environment: [:])
            for _ in 0..<5 { t.equal((try? reader(ctx)) ?? nil, mgmtKey) }
            t.equal(fake.recorded.count, 1, "the Keychain is read once")
            memo.set(.key("sk-or-v1-replaced-by-save-000"))
            t.equal((try? reader(ctx)) ?? nil, "sk-or-v1-replaced-by-save-000", "Save updates the memo")
            memo.set(.absent)
            t.check(((try? reader(ctx)) ?? nil) == nil, "Remove → no key")
            memo.invalidate()
            _ = try? reader(ctx)
            t.equal(fake.recorded.count, 2, "invalidate → one new read")

            let refusing = FakeSecurity(answer: { _ in CommandResult(status: 51) })
            let memo2 = ManagementKeyMemo()
            let r2 = OpenRouterCollector.defaultManagementKeyReader(memo: memo2, tool: refusing.tool)
            var message = ""
            for _ in 0..<3 {
                do { _ = try r2(ctx) } catch let e as ManagementKeyReadError { message = e.message } catch {}
            }
            t.equal(refusing.recorded.count, 1, "a refused prompt is not repeated in this run")
            t.check(memo2.readWasDenied, "Settings can say: re-save")
            t.check(message.contains("Re-save the key once to stop Keychain prompts"), message)

            let stuck = FakeSecurity(answer: { _ in CommandResult(status: -1, timedOut: true) })
            let memo3 = ManagementKeyMemo()
            let r3 = OpenRouterCollector.defaultManagementKeyReader(memo: memo3, tool: stuck.tool)
            _ = try? r3(ctx); _ = try? r3(ctx)
            t.equal(stuck.recorded.count, 2, "a timeout is retried next refresh")
            t.check(!memo3.readWasDenied, "a timeout is not a denial")
        }
    }

    static let metaURL = "https://openrouter.ai/api/v1/analytics/meta"
    static let queryURL = "https://openrouter.ai/api/v1/analytics/query"

    static func metaDoc(_ metrics: [String]) -> String { #"{"data":{"metrics":["# + metrics.joined(separator: ",") + #"],"granularities":[{"name":"month"}],"dimensions":[],"operators":[]}}"# }
    static func metric(_ name: String, label: String = "", format: String = "currency", rate: Bool = false) -> String {
        #"{"name":"\#(name)","display_label":"\#(label)","is_rate":\#(rate),"display_format":"\#(format)"}"#
    }

    static func doc(_ json: String) -> [String: Any] { Sanitize.jsonObject(Data(json.utf8)) ?? [:] }

    static func analytics(_ t: TestRun) async {
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { Date(timeIntervalSince1970: LogicTests.utc(y, m, d, h) / 1000) }

        // Metric selection.
        let pick = OpenRouterCollector.pickCostMetric
        t.equal(pick(doc(metaDoc([metric("requests", label: "Requests", format: "number"), metric("cost", label: "Cost")]))), "cost")
        t.equal(pick(doc(metaDoc([metric("cost_per_token", label: "Cost per token", rate: true),
                                  metric("byok_cost", label: "BYOK cost"),
                                  metric("total_usage", label: "Usage")]))), "total_usage", "no rates, no BYOK; exact name wins")
        t.equal(pick(doc(metaDoc([metric("upstream_spend", label: "Upstream spend"), metric("billed", label: "Billed cost")]))),
                "billed", "label mentioning cost beats spend")
        t.equal(pick(doc(metaDoc([metric("latency", label: "Latency", format: "latency"), metric("tokens", format: "number")]))), nil)
        t.equal(pick(doc(metaDoc([metric("cost\\\"} evil", label: "Cost")]))), nil, "odd names are never put in a body")
        t.equal(pick(doc(#"{"data":{}}"#)), nil)

        // Query body: exact JSON, seconds, year boundaries.
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2026, 11, 19, 12)),
                #"{"metrics":["cost"],"granularity":"month","time_range":{"start":"2026-09-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}}"#)
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2027, 1, 15)),
                #"{"metrics":["cost"],"granularity":"month","time_range":{"start":"2026-11-01T00:00:00Z","end":"2027-01-01T00:00:00Z"}}"#)
        t.equal(OpenRouterCollector.queryBody(metric: "cost", now: at(2027, 2, 1)),
                #"{"metrics":["cost"],"granularity":"month","time_range":{"start":"2026-12-01T00:00:00Z","end":"2027-02-01T00:00:00Z"}}"#)
        t.equal(OpenRouterCollector.rangeLabel(at(2026, 11, 1)), "Nov\u{2013}Dec")
        t.equal(OpenRouterCollector.rangeLabel(at(2026, 12, 1)), "Dec\u{2013}Jan")
        t.equal(OpenRouterCollector.monthKey(at(2027, 1, 31, 23)), "2027-01")

        // Defensive parsing.
        let start = at(2026, 9, 1), end = at(2026, 11, 1)
        func parse(_ json: String) -> Double? { OpenRouterCollector.parseTotal(doc(json), metric: "cost", start: start, end: end) }
        t.equal(parse(#"{"data":{"data":[{"date":"2026-09-01T00:00:00Z","cost":60},{"date":"2026-10-01","cost":"62.4"}],"metadata":{"row_count":2,"truncated":false}}}"#), 122.4)
        t.equal(parse(#"{"data":{"data":[{"cost":60,"x":1},{"cost":62.4}]}}"#), 122.4, "two rows, no buckets")
        t.equal(parse(#"{"data":{"data":[{"month":"2026-10","cost":50}],"metadata":{"row_count":1,"truncated":false}}}"#), 50,
                "one row, complete answer: the missing month is 0")
        t.equal(parse(#"{"data":{"data":[{"cost":50}],"metadata":{"row_count":1,"truncated":false}}}"#), nil, "one row without a bucket")
        t.equal(parse(#"{"data":{"data":[{"month":"2026-10","cost":50}]}}"#), nil, "one row, no metadata")
        t.equal(parse(#"{"data":{"data":[{"cost":1},{"cost":2}],"metadata":{"truncated":true}}}"#), nil, "truncated")
        t.equal(parse(#"{"data":{"data":[{"cost":1},{"cost":2},{"cost":3}]}}"#), nil, "too many rows")
        t.equal(parse(#"{"data":{"data":[{"cost":-1},{"cost":2}]}}"#), nil, "negative")
        t.equal(parse(#"{"data":{"data":[{"spend":1},{"cost":2}]}}"#), nil, "metric missing")
        t.equal(parse(#"{"data":{"data":[{"date":"2026-08-01","cost":1},{"cost":2}]}}"#), nil, "bucket outside the range")
        t.equal(parse(#"{"data":{"data":[{"date":"2026-10-01","cost":1},{"date":"2026-10-15","cost":2}]}}"#), nil, "same month twice")
        t.equal(parse(#"{"data":[]}"#), nil)
        t.equal(parse(#"{"data":{"data":[],"metadata":{"row_count":0,"truncated":false}}}"#), 0, "no spend at all → 0 (no meter)")

        // End to end: once per month, cached with the provider, never an error.
        let creditsOK = #"{"data":{"total_credits":535,"total_usage":514.19}}"#
        let keys = keysDoc([keyJSON(hash: "aaaa1111", name: "hermes", monthly: 49.93)])
        let queryOK = #"{"data":{"data":[{"date":"2026-09-01T00:00:00Z","cost":60},{"date":"2026-10-01T00:00:00Z","cost":62.4}],"metadata":{"row_count":2,"truncated":false,"query_time_ms":12},"warnings":[]}}"#
        let routes: [String: OpenRouterStubHTTP.Reply] = [
            keysPage0: .json(200, keys), creditsURL: .json(200, creditsOK),
            metaURL: .json(200, metaDoc([metric("requests", format: "number"), metric("cost", label: "Cost")])),
            "POST " + queryURL: .json(200, queryOK),
        ]
        do {
            let memo = AnalyticsMemo()
            let c = OpenRouterCollector(managementKeyReader: { _ in mgmtKey }, analytics: memo)
            let http = OpenRouterStubHTTP(routes)
            let home = Fixtures.tempHome("or-analytics")
            let p = await c.collect(mgmtContext(home: home, http: http))
            t.equal(p.error, "")
            t.equal(p.money?.baseline, MonthlyBaseline(month: "2026-11", average: 61.2, months: 2, label: "Sep\u{2013}Oct"))
            t.equal(http.calls.map(\.url), [keysPage0, creditsURL, metaURL, "POST " + queryURL])
            t.equal(http.bodies, [#"{"metrics":["cost"],"granularity":"month","time_range":{"start":"2026-09-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}}"#])
            let post = http.calls.last?.headers
            t.equal(post?["Content-Type"], "application/json")
            t.equal(post?["Authorization"], "Bearer \(mgmtKey)")

            // The panel meter and caption, the bar figure and meter.
            let w = Meters.windowsFor(p)[0]
            t.equal(w.mode, .meter)
            t.near(w.percent, 49.93 / 61.2 * 100, 0.001)
            t.equal(Summary.windowCaption(w, now: mgmtNow.timeIntervalSince1970 * 1000),
                    "$49.93 of $61.20 avg (Sep\u{2013}Oct) \u{00B7} Resets in 11d 12h")
            t.equal(Meters.barDollarsText(p), "$20.81")
            t.equal(Meters.barMeters(p).map(\.key), ["cycle"])
            t.equal(Summary.accountWideBarText(p), "$20.81 \u{00B7} 81.6%")

            // Same run, same month: no second query.
            let again = await c.collect(mgmtContext(home: home, http: http))
            t.equal(again.money?.baseline?.average, 61.2)
            t.equal(http.calls.filter { $0.url.contains("analytics") }.count, 2, "meta + query once per run and month")

            // A restart with the cached baseline (UsageCache round trip): no analytics at all.
            let cache = UsageCache(providers: [p]).serialize()
            let restored = UsageCache.parse(cache, now: mgmtNow.timeIntervalSince1970 * 1000)
            let cachedBaseline = restored?.providers.first?.money?.baseline
            t.equal(cachedBaseline, p.money?.baseline, "baseline survives the cache")
            let fresh = OpenRouterCollector(managementKeyReader: { _ in mgmtKey }, analytics: AnalyticsMemo())
            let http2 = OpenRouterStubHTTP(routes)
            var ctx = mgmtContext(home: home, http: http2)
            ctx.openrouterBaseline = cachedBaseline
            let p2 = await fresh.collect(ctx)
            t.equal(p2.money?.baseline?.average, 61.2)
            t.equal(http2.calls.filter { $0.url.contains("analytics") }.count, 0, "cached this month → no query")

            // Next month the cached one is stale: query again (for Oct–Nov).
            let http3 = OpenRouterStubHTTP(routes.merging(["POST " + queryURL: .json(200,
                #"{"data":{"data":[{"date":"2026-10-01","cost":62.4},{"date":"2026-11-01","cost":49.93}]}}"#)]) { $1 })
            var dec = CollectorContext(home: home, environment: [:], searchPath: ["/usr/bin"], now: at(2026, 12, 2), http: http3.client)
            dec.openrouterBaseline = cachedBaseline
            let p3 = await c.collect(dec)
            t.equal(p3.money?.baseline?.month, "2026-12")
            t.equal(p3.money?.baseline?.label, "Oct\u{2013}Nov")
            t.equal(http3.calls.filter { $0.url == metaURL }.count, 0, "metric name remembered for the run")
        }

        // Unavailable analytics → no baseline, no error, at most one try this month; history takes over.
        do {
            for (name, extra) in [("meta 404", [metaURL: OpenRouterStubHTTP.Reply.json(404, "{}")]),
                                  ("no cost metric", [metaURL: .json(200, metaDoc([metric("requests", format: "number")]))]),
                                  ("query 500", ["POST " + queryURL: .json(500, "{}")]),
                                  ("odd rows", ["POST " + queryURL: .json(200, #"{"data":{"data":[{"cost":1},{"cost":2},{"cost":3}]}}"#)]),
                                  ("offline", ["POST " + queryURL: .fail(.transport("offline"))])] {
                let memo = AnalyticsMemo()
                let c = OpenRouterCollector(managementKeyReader: { _ in mgmtKey }, analytics: memo)
                let http = OpenRouterStubHTTP(routes.merging(extra) { $1 })
                let p = await c.collect(mgmtContext(home: Fixtures.tempHome("or-analytics-bad"), http: http))
                t.equal(p.error, "", "\(name): not an error")
                t.check(p.money?.baseline == nil, "\(name): no baseline")
                t.equal(p.money?.spend, 49.93, "\(name): the rest still works")
                let before = http.calls.count
                _ = await c.collect(mgmtContext(home: Fixtures.tempHome("or-analytics-bad2"), http: http))
                t.equal(http.calls.count - before, 2, "\(name): only keys + credits the second time")
                t.equal(Meters.windowsFor(p)[0].mode, .dollars, "\(name): no baseline, no history → dollars")
            }
            // GET-only client: never attempts analytics.
            let getOnly = OpenRouterStubHTTP(routes)
            let plain = HTTPClient { url, h in try await getOnly.client.get(url, h) }
            let c = OpenRouterCollector(managementKeyReader: { _ in mgmtKey }, analytics: AnalyticsMemo())
            let p = await c.collect(CollectorContext(home: Fixtures.tempHome("or-getonly"), environment: [:], now: mgmtNow, http: plain))
            t.check(p.money?.baseline == nil, "no POST, no baseline")
            t.equal(getOnly.calls.map(\.url), [keysPage0, creditsURL])
        }

        // History keeps two completed cycles; old caches still parse.
        do {
            let dec1 = LogicTests.utc(2026, 12, 1), nov1 = LogicTests.utc(2026, 11, 1), oct1 = LogicTests.utc(2026, 10, 1)
            var h = CycleHistory.empty
            h = h.advanced(with: Money(spend: 50, resetsAt: oct1), now: oct1 - 3_600_000)
            h = h.advanced(with: Money(spend: 60, resetsAt: nov1), now: nov1 - 3_600_000)
            h = h.advanced(with: Money(spend: 10, resetsAt: dec1), now: nov1 + 3_600_000)
            t.equal(h.current?.end, dec1)
            t.equal(h.previous?.spend, 60)
            t.equal(h.older?.spend, 50, "the cycle before previous is kept")
            t.equal(h.completedCycles().map(\.spend), [60, 50])
            // A missed end breaks the chain.
            let gap = h.advanced(with: Money(spend: 1, resetsAt: LogicTests.utc(2027, 2, 1)), now: LogicTests.utc(2027, 1, 15))
            t.check(gap.previous == nil && gap.older == nil, "unobserved end → no baseline")
            // An older that doesn't end before previous is dropped.
            let bad = CycleHistory(current: h.current, previous: h.previous, older: Cycle(key: "x", end: dec1, spend: 1, lastObservedAt: 1)).normalized()
            t.check(bad.older == nil, "older must end before previous")
            let legacy = #"{"current":{"key":"c","end":\#(dec1),"spend":3,"lastObservedAt":1},"previous":{"key":"p","end":\#(nov1),"spend":4,"lastObservedAt":\#(nov1)}}"#
            let decoded = try? JSONDecoder().decode(CycleHistory.self, from: Data(legacy.utf8))
            t.check(decoded != nil && decoded?.older == nil && decoded?.previous?.spend == 4, "a 1.0 history reads without older")
            let legacyMoney = #"{"label":"All keys","spend":3,"resetInterval":"monthly","resetsAt":0}"#
            t.check((try? JSONDecoder().decode(Money.self, from: Data(legacyMoney.utf8)))?.baseline == nil, "money without baseline reads")
        }
    }
}
