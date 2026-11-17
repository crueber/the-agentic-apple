import Foundation
import AgenticCore

/// Grok: unified.jsonl billing snapshot, session ledgers, Grok Bot blob cache.
/// Every fixture is synthetic; HOME is a temporary directory.
enum GrokTests {
    /// "Now" for every case: 2026-11-17T12:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_794_916_800)
    static let fm = FileManager.default

    static func context(_ home: URL, environment: [String: String] = [:], grokHome: String = "",
                        botHome: String = "", now: Date = now) -> CollectorContext {
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        env.merge(environment) { _, new in new }
        return CollectorContext(home: home, environment: env, searchPath: ["/usr/bin", "/bin"],
                                grokHome: grokHome, botHome: botHome, now: now)
    }

    static func copy(_ fixture: String, to dest: URL) {
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: Fixtures.url(fixture), to: dest)
    }

    static func setMtime(_ url: URL, _ date: Date) {
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    static let appSupportBot = "Library/Application Support/Grok Bot/sand-client-persistence"

    /// A home with the fixture ~/.grok and the Grok Bot cache in Application Support.
    static func fullHome(_ label: String) -> URL {
        let home = Fixtures.tempHome(label)
        copy("grok/home/.grok", to: home.appendingPathComponent(".grok"))
        copy("grok/bot", to: home.appendingPathComponent(appSupportBot))
        // sess-4 has an in-period turn, but its ledger is older than the scan cutoff.
        setMtime(home.appendingPathComponent(".grok/sessions/ws-beta/sess-4/usage.json"),
                 Date(timeIntervalSince1970: 1_793_491_200)) // 2026-11-01
        return home
    }

    static func billingLine(ts: String, tier: String = "SuperGrok", used: String = "\"creditUsagePercent\":20,",
                            type: String = "BILLING_PERIOD_TYPE_WEEKLY",
                            start: String = "2026-11-16T00:00:00.000Z", end: String = "2026-11-23T00:00:00.000Z") -> String {
        "{\"ts\":\"\(ts)\",\"msg\":\"billing: fetched credits config\",\"ctx\":{\"subscriptionTier\":\"\(tier)\",\"config\":{\(used)\"currentPeriod\":{\"type\":\"\(type)\",\"start\":\"\(start)\",\"end\":\"\(end)\"}}}}"
    }

    static func writeLog(_ home: URL, _ text: String) {
        let logs = home.appendingPathComponent(".grok/logs")
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try? text.write(to: logs.appendingPathComponent("unified.jsonl"), atomically: true, encoding: .utf8)
    }

    static func run(_ t: TestRun) async {
        t.suite("Grok")
        let c = GrokCollector()

        // Full fixture: latest complete snapshot wins over an older one and a torn tail line.
        do {
            let home = fullHome("grok-full")
            let p = await c.collect(context(home))
            t.equal(p.id, .grok)
            t.equal(p.available, true, "available with a snapshot")
            t.equal(p.tier, "SuperGrok", "tier")
            t.equal(p.source, "grok-log")
            t.equal(p.error, "", "no error")
            t.near(p.readAt, 1_794_907_800_000, 0.5, "readAt is the snapshot time")
            t.equal(p.limits.count, 2, "plan + bot")
            if p.limits.count == 2 {
                let w = p.limits[0]
                t.equal(w.key, "weekly")
                t.equal(w.label, "Weekly limit")
                t.equal(w.short, "wk")
                t.near(w.percent, 37.5, 0.001, "latest snapshot's percent")
                t.near(w.resetsAt, 1_795_392_000_000, 0.5, "period end")
                t.equal(w.stale, false)
                let b = p.limits[1]
                t.equal(b.key, "bot")
                t.equal(b.label, "Grok Bot weekly")
                t.equal(b.short, "bot")
                t.near(b.percent, 42, 0.001, "newest blob wins; .txt and junk ignored")
                t.near(b.resetsAt, 1_795_132_800_000, 0.5)
                t.equal(b.stale, false)
            }
            // sess-1: two turns in period (1000 + 2500); sess-2: legacy session total (3 / 4000);
            // sess-3 updated before the period; sess-4 older than the mtime cutoff.
            t.equal(p.activity.period, "week")
            t.equal(p.activity.prompts, 5, "turns this period")
            t.equal(p.activity.tokens, 7500, "tokens this period")
        }

        // Grok Bot reading past its expiry (or reset) is stale.
        do {
            let home = fullHome("grok-bot-stale")
            let later = Date(timeIntervalSince1970: 1_795_132_800 + 3600) // 2026-11-20T01:00Z
            let p = await c.collect(context(home, now: later))
            let bot = p.limits.first { $0.key == "bot" }
            t.check(bot != nil, "bot limit present")
            t.equal(bot?.stale, true, "bot stale past expiry")
            t.equal(p.limits.first?.stale, false, "plan period still current")
        }

        // Expired plan period is stale; a monthly period gets the monthly label.
        do {
            let home = Fixtures.tempHome("grok-monthly")
            writeLog(home, billingLine(ts: "2026-10-31T10:00:00Z", type: "MONTHLY",
                                       start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z") + "\n")
            let p = await c.collect(context(home))
            t.equal(p.limits.count, 1, "no bot cache → plan only")
            t.equal(p.limits.first?.label, "Monthly limit")
            t.equal(p.limits.first?.short, "mo")
            t.equal(p.limits.first?.stale, true, "period ended")
            t.equal(p.activity.period, "today", "no sessions dir → no weekly activity")
            t.equal(p.available, true)
        }

        // Daily period; missing creditUsagePercent reads as 0 (fresh period).
        do {
            let home = Fixtures.tempHome("grok-daily")
            writeLog(home, billingLine(ts: "2026-11-17T01:00:00Z", used: "", type: "DAY",
                                       start: "2026-11-17T00:00:00Z", end: "2026-11-18T00:00:00Z"))
            let p = await c.collect(context(home))
            t.equal(p.limits.first?.label, "Daily limit")
            t.equal(p.limits.first?.short, "day")
            t.near(p.limits.first?.percent ?? -1, 0, 0.001, "absent percent is 0")
        }

        // Out-of-range percent is clamped.
        do {
            let home = Fixtures.tempHome("grok-clamp")
            writeLog(home, billingLine(ts: "2026-11-17T01:00:00Z", used: "\"creditUsagePercent\":180,"))
            let p = await c.collect(context(home))
            t.near(p.limits.first?.percent ?? -1, 100, 0.001, "clamped")
        }

        // A snapshot far back in a large log with multibyte noise across chunk boundaries.
        do {
            let home = Fixtures.tempHome("grok-big")
            var log = billingLine(ts: "2026-11-17T02:00:00Z", used: "\"creditUsagePercent\":64,") + "\n"
            let noise = "{\"msg\":\"tool: output\",\"ctx\":{\"text\":\"" + String(repeating: "ü✓é", count: 97) + "\"}}\n"
            while log.utf8.count < 900 * 1024 { log += noise }
            writeLog(home, log)
            let p = await c.collect(context(home))
            t.near(p.limits.first?.percent ?? -1, 64, 0.001, "found past several chunks")
        }

        // No ~/.grok at all: not installed, nothing to say.
        do {
            let home = Fixtures.tempHome("grok-none")
            let p = await c.collect(context(home))
            t.equal(p.available, false)
            t.equal(p.error, "", "not installed is not an error")
            t.equal(p.limits.count, 0)
        }

        // ~/.grok exists but has no log yet / no snapshot yet.
        do {
            let home = Fixtures.tempHome("grok-nolog")
            try? fm.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
            let p = await c.collect(context(home))
            t.equal(p.available, false)
            t.check(p.error.contains("no Grok log"), "missing log reason: \(p.error)")
            t.check(p.hint.contains("grok"), "hint says to run grok")

            writeLog(home, "{\"msg\":\"shell: started\"}\n{\"msg\":\"billing: fetched credits config\",\"ctx\":{}}\n")
            let q = await c.collect(context(home))
            t.equal(q.available, false)
            t.check(q.error.contains("no recognizable config"), "unparseable snapshot: \(q.error)")

            writeLog(home, "{\"msg\":\"shell: started\"}\n")
            let r = await c.collect(context(home))
            t.check(r.error.contains("no billing snapshot"), "no snapshot: \(r.error)")
        }

        // grokHome override and $GROK_HOME; botHome override; ~/.config fallback.
        do {
            let home = Fixtures.tempHome("grok-overrides")
            let custom = home.appendingPathComponent("elsewhere/grok")
            copy("grok/home/.grok", to: custom)
            let bots = home.appendingPathComponent("elsewhere/bot")
            copy("grok/bot", to: bots)

            let a = await c.collect(context(home, grokHome: custom.path))
            t.equal(a.available, true, "grokHome override")
            t.equal(a.limits.count, 1, "no bot cache in the default places")

            let b = await c.collect(context(home, environment: ["GROK_HOME": custom.path]))
            t.equal(b.available, true, "$GROK_HOME")

            let d = await c.collect(context(home, grokHome: custom.path, botHome: bots.path))
            t.near(d.limits.last?.percent ?? -1, 42, 0.001, "botHome override")

            copy("grok/bot", to: home.appendingPathComponent(".config/Grok Bot/sand-client-persistence"))
            let e = await c.collect(context(home, grokHome: custom.path))
            t.equal(e.limits.last?.key, "bot", "~/.config fallback")
        }

        // The Application Support cache wins over ~/.config.
        do {
            let home = fullHome("grok-bot-order")
            let cfg = home.appendingPathComponent(".config/Grok Bot/sand-client-persistence")
            try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
            try? "{\"value\":{\"reading\":{\"readAtMs\":1794916000000,\"usage\":{\"percentUsed\":77,\"nextResetMs\":1795132800000}}}}"
                .write(to: cfg.appendingPathComponent("x.blob"), atomically: true, encoding: .utf8)
            let p = await c.collect(context(home))
            t.near(p.limits.last?.percent ?? -1, 42, 0.001, "Application Support first")
        }
    }
}
