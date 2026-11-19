import Foundation
import AgenticCore

/// OpenRouter with a management key (account-wide). Offline: stubbed HTTP and an
/// injected key reader — never the real Keychain or network.
extension OpenRouterTests {
    static let mgmtKey = "sk-or-v1-demo-management-key-9999"
    static let keysPage0 = "https://openrouter.ai/api/v1/keys?offset=0"
    static let fullLabel = "sk-or-v1-0e6...1c96"

    static func iso(_ ms: Double) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// 2026-11-19 12:00 UTC, a Thursday.
    static let mgmtNow = Date(timeIntervalSince1970: LogicTests.utc(2026, 11, 19, 12) / 1000)

    static func keysDoc(_ items: [String]) -> String { #"{"data":["# + items.joined(separator: ",") + "]}" }

    static func keyJSON(hash: String, name: String?, label: String = fullLabel, disabled: Bool = false,
                        limit: String = "null", remaining: String = "null", reset: String = "null",
                        usage: Double = 1, daily: Double = 0.5, weekly: Double = 2, monthly: Double = 4,
                        expires: String = "null") -> String {
        let n = name.map { "\"\($0)\"" } ?? "null"
        return """
        {"hash":"\(hash)","name":\(n),"label":"\(label)","disabled":\(disabled),"limit":\(limit),\
        "limit_remaining":\(remaining),"limit_reset":\(reset),"include_byok_in_limit":false,\
        "usage":\(usage),"usage_daily":\(daily),"usage_weekly":\(weekly),"usage_monthly":\(monthly),\
        "byok_usage":0,"byok_usage_daily":0,"byok_usage_weekly":0,"byok_usage_monthly":0,\
        "created_at":"2026-01-01T00:00:00Z","updated_at":null,"last_used_at":null,"expires_at":\(expires),\
        "creator_user_id":"user_demo","workspace_id":"ws_demo","external_user":null}
        """
    }

    static func mgmtContext(home: URL, env: [String: String] = [:], http: OpenRouterStubHTTP) -> CollectorContext {
        CollectorContext(home: home, environment: env, searchPath: ["/usr/bin", "/bin"], now: mgmtNow, http: http.client)
    }

    static func management(_ t: TestRun) async {
        let reader: OpenRouterCollector.ManagementKeyReader = { _ in "  \(mgmtKey)\n" }
        let c = OpenRouterCollector(managementKeyReader: reader)
        let creditsOK = #"{"data":{"total_credits":100.5,"total_usage":25.75}}"#
        let pastMs = LogicTests.utc(2026, 11, 1)
        let futureMs = LogicTests.utc(2027, 1, 1)
        let keys = keysDoc([
            // monthly, remaining given: (100 − 74.5) / 100 = 25.5%
            keyJSON(hash: "f01d4a2b99c3", name: "My Production Key", limit: "100", remaining: "74.5", reset: "\"monthly\"",
                    monthly: 25.5),
            // weekly, no remaining: usage_weekly 9 / 10 = 90%
            keyJSON(hash: "a1b2c3d4e5f6", name: nil, label: "sk-or-v1-abc...beef", limit: "10", reset: "\"weekly\"",
                    weekly: 9, monthly: 12),
            // daily, exhausted → limited
            keyJSON(hash: "0000aaaa1111", name: "Bot <b>", limit: "5", remaining: "0", reset: "\"daily\"", monthly: 3),
            // no reset: usage / limit = 2 / 4 = 50%, resetsAt 0
            keyJSON(hash: "9999ffff", name: "Lifetime", limit: "4", usage: 2, monthly: 1, expires: "\"\(iso(futureMs))\""),
            // no limit: no row, but counts and spends
            keyJSON(hash: "nolimit01", name: "Unlimited", monthly: 0.25),
            // disabled and expired: excluded from everything
            keyJSON(hash: "disabled01", name: "Old", disabled: true, limit: "1", remaining: "0", monthly: 50),
            keyJSON(hash: "expired001", name: "Gone", limit: "1", remaining: "0", monthly: 70, expires: "\"\(iso(pastMs))\""),
        ])

        // Management key wins over an inference key; /key is never called.
        do {
            let home = Fixtures.tempHome("or-mgmt")
            let http = OpenRouterStubHTTP([keysPage0: .json(200, keys), creditsURL: .json(200, creditsOK),
                                           keyURL: .fixture(200, "key.json")])
            let p = await c.collect(mgmtContext(home: home, env: ["OPENROUTER_API_KEY": envKey], http: http))
            t.equal(http.calls.map(\.url), [keysPage0, creditsURL], "keys then credits, no /key")
            t.check(http.calls.allSatisfy { $0.headers["Authorization"] == "Bearer \(mgmtKey)" }, "management key, trimmed")
            t.equal(p.available, true)
            t.equal(p.error, "")
            t.equal(p.tier, "Management key")
            t.equal(p.status, "5 keys", "enabled, non-expired keys")
            t.equal(p.source, "openrouter-management")
            t.equal(p.readAt, mgmtNow.timeIntervalSince1970 * 1000)

            let m = p.money
            t.equal(m?.label, "All keys")
            t.check(m?.limit == nil, "no single limit")
            t.near(m?.spend ?? -1, 25.5 + 12 + 3 + 1 + 0.25, 0.0001, "Σ usage_monthly of active keys")
            t.near(m?.credits ?? -1, 74.75, 0.0001, "credits left")
            t.near(m?.totalCredits ?? -1, 100.5, 0.0001, "credits total")
            t.equal(m?.resetInterval, "monthly")
            t.equal(m?.resetsAt, LogicTests.utc(2026, 12, 1), "next 1st, 00:00 UTC")

            t.equal(p.limits.map(\.key), ["credits", "key-0000aaaa", "key-a1b2c3d4", "key-9999ffff", "key-f01d4a2b"],
                    "credits first, keys by percent (limited daily key at 100%)")
            let byKey = Dictionary(uniqueKeysWithValues: p.limits.map { ($0.key, $0) })
            t.near(byKey["credits"]?.percent ?? -1, 25.75 / 100.5 * 100, 0.0001, "credits percent")
            t.equal(byKey["credits"]?.label, "Credits")
            t.equal(byKey["credits"]?.short, "cr")
            t.equal(byKey["credits"]?.resetsAt, 0)
            t.near(byKey["key-f01d4a2b"]?.percent ?? -1, 25.5, 0.0001, "percent from limit_remaining")
            t.near(byKey["key-a1b2c3d4"]?.percent ?? -1, 90, 0.0001, "percent from usage_weekly")
            t.near(byKey["key-9999ffff"]?.percent ?? -1, 50, 0.0001, "no reset: usage / limit")
            t.equal(byKey["key-0000aaaa"]?.limited, true, "limit_remaining 0 → limited")
            t.equal(byKey["key-f01d4a2b"]?.limited, false)
            t.equal(byKey["key-f01d4a2b"]?.resetsAt, LogicTests.utc(2026, 12, 1), "monthly reset")
            t.equal(byKey["key-a1b2c3d4"]?.resetsAt, LogicTests.utc(2026, 11, 23), "weekly → next Monday")
            t.equal(byKey["key-0000aaaa"]?.resetsAt, LogicTests.utc(2026, 11, 20), "daily → next midnight")
            t.equal(byKey["key-9999ffff"]?.resetsAt, 0, "null reset → 0")
            t.equal(byKey["key-f01d4a2b"]?.label, "My Production Key")
            t.equal(byKey["key-a1b2c3d4"]?.label, "Key \u{2026}beef", "fallback: last 4 of the label")
            t.equal(byKey["key-0000aaaa"]?.label, "Bot \u{2039}b\u{203A}", "name sanitised")
            t.equal(byKey["key-a1b2c3d4"]?.short, "key")
            t.check(p.limits.allSatisfy { !$0.label.contains(fullLabel) && !$0.label.contains("sk-or-v1") },
                    "a label never carries the full key label")

            // The key never leaves: provider JSON, cache, nothing.
            let encoded = String(decoding: (try? JSONEncoder().encode(p)) ?? Data(), as: UTF8.self)
            t.check(!encoded.contains(mgmtKey) && !encoded.contains(fullLabel), "provider JSON carries no key or label")
            let cache = UsageCache(providers: [p]).serialize()
            t.check(!cache.contains(mgmtKey) && !cache.contains("sk-or"), "cache carries no key")
            t.equal(UsageCache.slim(p).limits.count, p.limits.count, "cache keeps every row")
        }

        // Pagination: 100 per page until a short page.
        do {
            let page0 = keysDoc((0..<100).map { keyJSON(hash: String(format: "p0%06d", $0), name: "k\($0)", monthly: 0.01) })
            let page1 = keysDoc([keyJSON(hash: "p1last", name: "last", limit: "2", remaining: "1", reset: "\"monthly\"", monthly: 1)])
            let http = OpenRouterStubHTTP([keysPage0: .json(200, page0),
                                           "https://openrouter.ai/api/v1/keys?offset=100": .json(200, page1),
                                           creditsURL: .json(200, creditsOK)])
            let p = await c.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-pages"), http: http))
            t.equal(http.calls.map(\.url), [keysPage0, "https://openrouter.ai/api/v1/keys?offset=100", creditsURL])
            t.equal(p.status, "101 keys")
            t.near(p.money?.spend ?? -1, 2, 0.0001, "spend across pages")
            t.equal(p.limits.map(\.key), ["credits", "key-p1last"])

            // Capped at 10 pages.
            var routes: [String: OpenRouterStubHTTP.Reply] = [creditsURL: .json(200, creditsOK)]
            for i in 0..<12 { routes["https://openrouter.ai/api/v1/keys?offset=\(i * 100)"] = .json(200, page0) }
            let capped = OpenRouterStubHTTP(routes)
            let pc = await c.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-cap"), http: capped))
            t.equal(capped.calls.filter { $0.url.contains("/keys") }.count, 10, "at most 10 pages")
            t.equal(pc.status, "1000 keys")

            // More than six limited keys: six rows, highest first.
            let many = keysDoc((0..<9).map { keyJSON(hash: "many\($0)xxxx", name: "K\($0)", limit: "10", remaining: "\(10 - $0)") })
            let pm = await c.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-many"),
                                                 http: OpenRouterStubHTTP([keysPage0: .json(200, many), creditsURL: .json(200, creditsOK)])))
            t.equal(pm.limits.count, 7, "credits + six keys")
            t.equal(pm.limits.dropFirst().map(\.label), ["K8", "K7", "K6", "K5", "K4", "K3"])
            // total_credits 0 → 0%.
            let pz = await c.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-zero"),
                                                 http: OpenRouterStubHTTP([keysPage0: .json(200, keysDoc([])),
                                                                           creditsURL: .json(200, #"{"data":{"total_credits":0,"total_usage":3}}"#)])))
            t.equal(pz.limits.first?.percent, 0, "no credits bought → 0%")
            t.equal(pz.status, "0 keys")
            t.equal(pz.available, true)
        }

        // The environment variable wins and the reader is never consulted.
        do {
            let called = Flag()
            let spy = OpenRouterCollector(managementKeyReader: { _ in called.set(); return "sk-or-v1-from-keychain-0000" })
            let http = OpenRouterStubHTTP([keysPage0: .json(200, keys), creditsURL: .json(200, creditsOK)])
            let p = await spy.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-env"),
                                                  env: ["OPENROUTER_MANAGEMENT_KEY": " sk-or-v1-from-env-key-1234 "], http: http))
            t.equal(p.source, "openrouter-management")
            t.equal(http.calls.first?.headers["Authorization"], "Bearer sk-or-v1-from-env-key-1234")
            t.check(!called.value, "Keychain not read when the variable is set")
        }

        // A malformed or missing management key: the per-key view, exactly as before.
        do {
            for bad in [nil, "", "   ", "short", "sk-or-v1 with spaces inside it"] as [String?] {
                let fallback = OpenRouterCollector(managementKeyReader: { _ in bad })
                let http = standardHTTP()
                let p = await fallback.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-bad"),
                                                           env: ["OPENROUTER_API_KEY": envKey], http: http))
                t.equal(p.source, "openrouter-api", "per-key view for \(String(describing: bad))")
                t.equal(http.calls.map(\.url), [keyURL, creditsURL])
                t.equal(p.limits.count, 0)
                t.equal(p.money?.label, "key \u{2026}1b2")
            }
        }

        // A Keychain that can't be read is an error (the merge keeps the last numbers), not "no key".
        do {
            struct Stuck: Error {}
            let stuck = OpenRouterCollector(managementKeyReader: { _ in throw Stuck() })
            let http = standardHTTP()
            let p = await stuck.collect(mgmtContext(home: Fixtures.tempHome("or-mgmt-stuck"),
                                                    env: ["OPENROUTER_API_KEY": envKey], http: http))
            t.equal(p.error, "The OpenRouter management key could not be read from the Keychain")
            t.equal(http.calls.count, 0, "no request, no switch to the inference key")
            t.check(p.money == nil && p.limits.isEmpty, "no numbers")
            var old = Provider(id: .openrouter, available: true, tier: "Management key", source: "openrouter-management")
            old.money = Money(label: "All keys", spend: 3, resetInterval: "monthly")
            let merged = ProviderMerge.merge(previous: [old], fresh: [p])[0]
            t.equal(merged.money, old.money, "last good numbers kept")
            t.equal(merged.error, p.error)
        }

        // Errors: plain wording, no fallback to the inference key, no numbers, no key.
        do {
            let home = Fixtures.tempHome("or-mgmt-errors")
            let env = ["OPENROUTER_API_KEY": envKey]
            func run(_ routes: [String: OpenRouterStubHTTP.Reply]) async -> (Provider, OpenRouterStubHTTP) {
                let http = OpenRouterStubHTTP(routes)
                return (await c.collect(mgmtContext(home: home, env: env, http: http)), http)
            }
            let echo = #"{"error":{"code":401,"message":"API key expired \#(mgmtKey)"}}"#
            let (p401, h401) = await run([keysPage0: .json(401, echo)])
            t.equal(p401.status, "Management key expired or invalid")
            t.equal(p401.hint, "Create a new one at openrouter.ai/settings/management-keys and save it in Settings")
            t.check(p401.error.contains("HTTP 401"), "401 error: \(p401.error)")
            t.check(p401.error.contains("The inference key isn't used while a management key is set."), "says no fallback")
            t.equal(p401.available, true, "a detected key shows its error")
            t.check(p401.money == nil && p401.limits.isEmpty, "no numbers on error")
            t.equal(h401.calls.map(\.url), [keysPage0], "no /key, no /credits after a 401")
            t.check(!p401.error.contains(mgmtKey) && !p401.status.contains(mgmtKey), "error never carries the key")

            let (p403, _) = await run([keysPage0: .json(403, #"{"error":{"message":"Forbidden"}}"#)])
            t.check(p403.error.hasPrefix("This management key isn't allowed to read the account's keys (HTTP 403)."), p403.error)
            let (p404, _) = await run([keysPage0: .json(404, "{}")])
            t.check(p404.error.hasPrefix("This management key can't list keys (personal accounts may need an organization)."), p404.error)
            let (pNet, _) = await run([keysPage0: .fail(.transport("The Internet connection appears to be offline."))])
            t.check(pNet.error.hasPrefix("The Internet connection appears to be offline."), pNet.error)
            let (pBad, _) = await run([keysPage0: .json(200, "nope")])
            t.check(pBad.error.hasPrefix("invalid JSON from OpenRouter"), pBad.error)
            let (p500, _) = await run([keysPage0: .json(500, #"{"error":{"message":"boom"}}"#)])
            t.check(p500.error.hasPrefix("boom (HTTP 500)"), p500.error)

            // Credits: 404 is tolerated (no Credits row); 401 is not.
            let (pNoCredits, _) = await run([keysPage0: .json(200, keys), creditsURL: .json(404, "{}")])
            t.equal(pNoCredits.error, "")
            t.equal(pNoCredits.limits.first?.key, "key-0000aaaa", "no Credits row")
            t.check(pNoCredits.money?.credits == nil, "no credits figure")
            let (pCredits401, _) = await run([keysPage0: .json(200, keys), creditsURL: .json(401, "{}")])
            t.equal(pCredits401.status, "Management key expired or invalid")
            t.check(pCredits401.money == nil, "no partial numbers")

            // The merge keeps the last good account-wide numbers and adds the error.
            let (good, _) = await run([keysPage0: .json(200, keys), creditsURL: .json(200, creditsOK)])
            let merged = ProviderMerge.merge(previous: [good], fresh: [p401])[0]
            t.equal(merged.limits, good.limits, "last good rows kept")
            t.equal(merged.money, good.money, "last good money kept")
            t.equal(merged.status, "Management key expired or invalid")
            t.equal(merged.error, p401.error)
            let cache = UsageCache(providers: [merged]).serialize()
            t.check(!cache.contains(mgmtKey), "cache carries no key after an error")
        }

        // Settings › Save verification.
        do {
            let ok = OpenRouterStubHTTP([keysPage0: .json(200, keys)])
            let v = await OpenRouterCollector.verifyManagementKey(" \(mgmtKey) ", http: ok.client, now: mgmtNow)
            t.equal(v.ok, true)
            t.equal(v.message, "Verified \u{00B7} 5 keys")
            t.equal(ok.calls.map(\.url), [keysPage0], "one /keys call")
            t.equal(ok.calls.first?.headers["Authorization"], "Bearer \(mgmtKey)")

            let one = await OpenRouterCollector.verifyManagementKey(mgmtKey, http: OpenRouterStubHTTP([keysPage0: .json(200, keysDoc([keyJSON(hash: "x", name: "x")]))]).client)
            t.equal(one.message, "Verified \u{00B7} 1 key")

            let bad = await OpenRouterCollector.verifyManagementKey(mgmtKey, http: OpenRouterStubHTTP([keysPage0: .json(401, #"{"error":{"message":"API key expired"}}"#)]).client)
            t.equal(bad.ok, false)
            t.check(bad.message.contains("HTTP 401") && !bad.message.contains(mgmtKey), bad.message)
            let missing = await OpenRouterCollector.verifyManagementKey(mgmtKey, http: OpenRouterStubHTTP([keysPage0: .json(404, "{}")]).client)
            t.equal(missing.message, "This management key can't list keys (personal accounts may need an organization).")

            let none = OpenRouterStubHTTP([:])
            let empty = await OpenRouterCollector.verifyManagementKey("  ", http: none.client)
            t.equal(empty.ok, false)
            t.equal(empty.message, "Paste a management key first")
            let spaced = await OpenRouterCollector.verifyManagementKey("sk-or-v1 abc def ghi jkl", http: none.client)
            t.equal(spaced.message, "A key has no spaces or special characters")
            let short = await OpenRouterCollector.verifyManagementKey("sk-or", http: none.client)
            t.equal(short.message, "That looks too short for an OpenRouter key")
            let long = await OpenRouterCollector.verifyManagementKey(String(repeating: "a", count: 600), http: none.client)
            t.equal(long.message, "That looks too long for an OpenRouter key")
            t.equal(none.calls.count, 0, "malformed keys are never sent")
        }

        // Keychain constants (the Settings writer and the collector reader must agree).
        t.equal(OpenRouterCollector.managementKeyService, "com.crueber.agentic-apple.openrouter-management-key")
        t.equal(OpenRouterCollector.managementKeyAccount, "default")
        t.check(SearchPath.importedVariables.contains("OPENROUTER_MANAGEMENT_KEY"), "imported from the login shell")
    }

    static func resetDates(_ t: TestRun) async {
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
        }
        func u(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Double { LogicTests.utc(y, m, d, h) }
        // Daily: strictly the next midnight.
        t.equal(OpenRouterCollector.nextDailyReset(at(2026, 11, 19, 23, 59, 59)), u(2026, 11, 20, 0))
        t.equal(OpenRouterCollector.nextDailyReset(at(2026, 11, 20)), u(2026, 11, 21, 0), "exact midnight → the next one")
        t.equal(OpenRouterCollector.nextDailyReset(at(2026, 12, 31, 18)), u(2027, 1, 1, 0), "year rollover")
        // Weekly: the next Monday.
        t.equal(OpenRouterCollector.nextWeeklyReset(at(2026, 11, 19, 12)), u(2026, 11, 23), "Thursday → Monday")
        t.equal(OpenRouterCollector.nextWeeklyReset(at(2026, 11, 22, 23, 59)), u(2026, 11, 23), "Sunday night → Monday")
        t.equal(OpenRouterCollector.nextWeeklyReset(at(2026, 11, 23)), u(2026, 11, 30), "Monday 00:00 → next Monday")
        t.equal(OpenRouterCollector.nextWeeklyReset(at(2026, 11, 23, 9)), u(2026, 11, 30), "Monday morning → next Monday")
        t.equal(OpenRouterCollector.nextWeeklyReset(at(2026, 12, 31, 8)), u(2027, 1, 4), "across the year")
        // Monthly: the next 1st.
        t.equal(OpenRouterCollector.nextMonthlyReset(at(2026, 11, 19, 12)), u(2026, 12, 1))
        t.equal(OpenRouterCollector.nextMonthlyReset(at(2026, 12, 1)), u(2027, 1, 1), "exact 1st → the next month")
        t.equal(OpenRouterCollector.nextMonthlyReset(at(2026, 12, 31, 23, 59, 59)), u(2027, 1, 1), "December → January")
        t.equal(OpenRouterCollector.nextMonthlyReset(at(2027, 1, 31, 12)), u(2027, 2, 1))
        // By name.
        t.equal(OpenRouterCollector.nextReset("daily", now: at(2026, 11, 19, 12)), u(2026, 11, 20))
        t.equal(OpenRouterCollector.nextReset("Weekly", now: at(2026, 11, 19, 12)), u(2026, 11, 23))
        t.equal(OpenRouterCollector.nextReset("monthly", now: at(2026, 11, 19, 12)), u(2026, 12, 1))
        t.equal(OpenRouterCollector.nextReset(nil, now: at(2026, 11, 19, 12)), 0)
        t.equal(OpenRouterCollector.nextReset("yearly", now: at(2026, 11, 19, 12)), 0)
    }
}

/// A thread-safe "was it called" flag for spies in `@Sendable` closures.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
