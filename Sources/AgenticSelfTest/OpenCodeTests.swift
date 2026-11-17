import Foundation
import AgenticCore

enum OpenCodeTests {
    /// A fixed "now" so "today" is deterministic.
    static let now = Date(timeIntervalSince1970: 1_794_931_200)  // 2026-11-17 mid-day UTC

    static func context(home: URL, opencode: String = "", env: [String: String] = [:],
                        searchPath: [String] = ["/usr/bin", "/bin"]) -> CollectorContext {
        CollectorContext(home: home, environment: env, searchPath: searchPath,
                         opencodeCommand: opencode, now: now)
    }

    /// A fake `opencode` that prints a fixture for `api …` and logs its argv.
    static func fake(_ home: URL, fixture: String, standaloneOnly: Bool = false) -> (bin: String, log: URL) {
        let log = home.appendingPathComponent("args.log")
        let file = Fixtures.url("opencode/" + fixture).path
        let gate = standaloneOnly ? #"[ "$2" = "--standalone" ] || { echo 'service not running'; exit 0; }"# : ":"
        let bin = Fixtures.fakeBinary(in: home, name: "opencode", script: """
            echo "$@" >> '\(log.path)'
            echo "HOME=$HOME" >> '\(log.path)'
            if [ "$1" = "api" ]; then
              \(gate)
              cat '\(file)'
              exit 0
            fi
            exit 1
            """)
        return (bin, log)
    }

    /// Build a synthetic SQLite store from a .sql fixture, anchored at local midnight of `now`.
    static func makeDB(_ dir: URL, fixture: String) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let midnight = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
        let sql = String(decoding: Fixtures.data("opencode/" + fixture), as: UTF8.self)
            .replacingOccurrences(of: "TODAY_MS", with: String(midnight))
        let db = dir.appendingPathComponent("opencode.db")
        let r = Shell.run("/usr/bin/sqlite3", [db.path], input: Data(sql.utf8), timeout: 10)
        return r.ok
    }

    static func run(_ t: TestRun) async {
        t.suite("OpenCode")
        let c = OpenCodeCollector()

        // Full Go answer (the reference test-collect.js case, extended).
        do {
            let home = Fixtures.tempHome("oc-full")
            let (bin, log) = fake(home, fixture: "limits.json")
            let p = await c.collect(context(home: home, opencode: bin))
            t.equal(p.id, .opencode)
            t.equal(p.available, true)
            t.equal(p.error, "")
            t.equal(p.source, "opencode-api")
            t.equal(p.status, "Go")
            t.equal(p.tier, "demo \u{2039}team\u{203A}", "workspace name, sanitised")
            t.check(p.readAt > 0, "readAt set")
            t.equal(p.limits.count, 3)
            t.equal(p.limits.map(\.key), ["session", "weekly", "monthly"])
            t.equal(p.limits.map(\.label), ["5-hour session", "Weekly (7-day)", "Monthly"])
            t.equal(p.limits.map(\.short), ["5h", "7d", "1m"])
            t.equal(p.limits.map(\.percent), [10, 20, 100], "clamped to 100")
            t.equal(p.limits.map(\.limited), [false, false, true])
            t.equal(p.limits.first?.resetsAt, 1_794_960_000_000, "epoch ms kept")
            t.equal(p.budgets.count, 1, "zero-limit budgets dropped")
            t.equal(p.budgets.first?.label, "console")
            t.equal(p.budgets.first?.percent, 25)
            t.equal(p.budgets.first?.spend, 2.5)
            t.equal(p.budgets.first?.limit, 10)
            let args = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            t.check(args.hasPrefix("api GET /api/experimental/usage/limits\n"), "first call, no retry: \(args)")
            t.check(!args.contains("--standalone"), "no retry when the service answers")
            t.check(args.contains("HOME=\(home.path)"), "child HOME is context.home")
        }

        // Background service down: retry once with --standalone, found on the search PATH.
        do {
            let home = Fixtures.tempHome("oc-standalone")
            let (bin, log) = fake(home, fixture: "limits.json", standaloneOnly: true)
            let dir = (bin as NSString).deletingLastPathComponent
            let p = await c.collect(context(home: home, searchPath: [dir, "/usr/bin", "/bin"]))
            t.equal(p.available, true, "standalone retry answers")
            t.equal(p.limits.count, 3)
            let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { !$0.hasPrefix("HOME=") }
            t.equal(calls, ["api GET /api/experimental/usage/limits",
                            "api --standalone GET /api/experimental/usage/limits"])
        }

        // Signed out: data null.
        do {
            let home = Fixtures.tempHome("oc-signedout")
            let p = await c.collect(context(home: home, opencode: fake(home, fixture: "signed-out.json").bin))
            t.equal(p.available, false)
            t.equal(p.status, "Not signed in")
            t.equal(p.error, "")
            t.equal(p.limits.count, 0)
        }

        // Signed in, no Go plan.
        do {
            let home = Fixtures.tempHome("oc-nogo")
            let p = await c.collect(context(home: home, opencode: fake(home, fixture: "limits-nogo.json").bin))
            t.equal(p.available, false)
            t.equal(p.status, "No Go plan")
            t.equal(p.limits.count, 0)
        }

        // An unwrapped answer (no `data` key) is used as the data itself; seconds → ms.
        do {
            let home = Fixtures.tempHome("oc-bare")
            let p = await c.collect(context(home: home, opencode: fake(home, fixture: "bare.json").bin))
            t.equal(p.available, true)
            t.equal(p.limits.count, 1, "only windows that report a percent")
            t.equal(p.limits.first?.percent, 42)
            t.equal(p.limits.first?.resetsAt, 1_794_960_000_000)
            t.equal(p.tier, "demo")
        }

        // Failures.
        do {
            let home = Fixtures.tempHome("oc-fail")
            let dead = Fixtures.fakeBinary(in: home, name: "opencode", script: "exit 2")
            let p = await c.collect(context(home: home, opencode: dead))
            t.equal(p.available, false)
            t.equal(p.error, "opencode did not answer")

            let home2 = Fixtures.tempHome("oc-weird")
            let weird = Fixtures.fakeBinary(in: home2, name: "opencode", script: #"echo '{"data":"nope"}'"#)
            let p2 = await c.collect(context(home: home2, opencode: weird))
            t.equal(p2.error, "opencode returned no usage data")

            let home3 = Fixtures.tempHome("oc-missing")
            let p3 = await c.collect(context(home: home3, searchPath: [home3.path]))
            t.equal(p3.available, false)
            t.equal(p3.error, "opencode not found")
        }

        // Today's activity from a synthetic OpenCode 2 store (session_message).
        do {
            let home = Fixtures.tempHome("oc-act2")
            let built = makeDB(home.appendingPathComponent(".local/share/opencode"), fixture: "activity-v2.sql")
            t.check(built, "built synthetic v2 store")
            let p = await c.collect(context(home: home, opencode: fake(home, fixture: "limits.json").bin))
            t.equal(p.activity.period, "today")
            t.equal(p.activity.prompts, 2, "user rows today only")
            t.equal(p.activity.tokens, 403, "input+output+reasoning+cache, today only")
        }

        // OpenCode 1 store (message.data.role) under XDG_DATA_HOME; activity survives an API failure.
        do {
            let home = Fixtures.tempHome("oc-act1")
            let xdg = home.appendingPathComponent("xdg")
            t.check(makeDB(xdg.appendingPathComponent("opencode"), fixture: "activity-v1.sql"), "built synthetic v1 store")
            let dead = Fixtures.fakeBinary(in: home, name: "opencode", script: "exit 1")
            let p = await c.collect(context(home: home, opencode: dead, env: ["XDG_DATA_HOME": xdg.path]))
            t.equal(p.error, "opencode did not answer")
            t.equal(p.activity.prompts, 1)
            t.equal(p.activity.tokens, 35)
        }

        // No store, or an unrelated database: empty activity, no error.
        do {
            let home = Fixtures.tempHome("oc-noact")
            let dir = home.appendingPathComponent(".local/share/opencode")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = Shell.run("/usr/bin/sqlite3", [dir.appendingPathComponent("opencode.db").path, "create table other(x);"])
            let p = await c.collect(context(home: home, opencode: fake(home, fixture: "limits.json").bin))
            t.equal(p.activity, Activity.empty)
            t.equal(p.error, "")
        }
    }
}
