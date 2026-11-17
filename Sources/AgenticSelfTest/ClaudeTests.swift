import Foundation
import AgenticCore

/// Claude: every test injects credentials and HTTP, uses a temp HOME and an
/// empty environment, so the real Keychain, ~/.claude and the network are
/// never touched. All data is synthetic.
enum ClaudeTests {
    static let token = "sk-ant-oat-SYNTHETIC-test-token"

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, [String: String])] = []
        func add(_ url: String, _ headers: [String: String]) { lock.withLock { items.append((url, headers)) } }
        var all: [(String, [String: String])] { lock.withLock { items } }
    }

    static func stub(_ calls: Calls, status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) -> HTTPClient {
        HTTPClient { url, h in
            calls.add(url, h)
            return HTTPResponse(status: status, body: body, headers: headers)
        }
    }

    static func context(_ home: URL, now: Date = Date(), http: HTTPClient, env: [String: String] = [:]) -> CollectorContext {
        CollectorContext(home: home, environment: env, searchPath: [], now: now, http: http)
    }

    static func creds(expiresIn seconds: Double = 3600, now: Date = Date(), tier: String = "default_claude_max_5x",
                      subscription: String = "max", token: String = token) -> ClaudeCollector.CredentialReader {
        let c = ClaudeCredentials(accessToken: token, expiresAt: (now.timeIntervalSince1970 + seconds) * 1000,
                                  subscriptionType: subscription, rateLimitTier: tier, source: "test")
        return { _ in c }
    }

    static func run(_ t: TestRun) async {
        t.suite("Claude")
        await normalLimits(t)
        utilizationScale(t)
        await planLabels(t)
        await expired(t)
        await refused(t)
        await rateLimitedAndErrors(t)
        await missingCredentials(t)
        credentialSources(t)
        await activity(t)
        incremental(t)
    }

    // MARK: limits

    static func normalLimits(_ t: TestRun) async {
        let home = Fixtures.tempHome("claude-limits")
        let calls = Calls()
        let now = Date()
        let collector = ClaudeCollector(credentialReader: creds(now: now))
        let p = await collector.collect(context(home, now: now, http: stub(calls, body: Fixtures.data("claude/usage.json"))))

        t.equal(calls.all.count, 1, "one probe")
        if let (url, h) = calls.all.first {
            t.equal(url, "https://api.anthropic.com/api/oauth/usage", "endpoint")
            t.equal(h["Authorization"] ?? "", "Bearer \(token)", "bearer header")
            t.equal(h["anthropic-beta"] ?? "", "oauth-2025-04-20", "beta header")
            t.equal(h["Accept"] ?? "", "application/json", "accept header")
        }
        t.check(p.available, "available with limits")
        t.equal(p.tier, "Max 5x", "tier")
        t.equal(p.status, "", "no status")
        t.equal(p.error, "", "no error")
        t.near(p.readAt, now.timeIntervalSince1970 * 1000, 1, "readAt")
        t.equal(p.limits.map(\.key), ["session", "weekly", "fable", "claude-zephyr-1-session", "sonnet"], "keys + order")
        t.equal(p.limits.map(\.label), ["Session (5-hour)", "Weekly (7-day)", "Fable Weekly", "claude-zephyr-1 Session", "Sonnet Weekly"], "labels")
        t.equal(p.limits.map(\.short), ["5h", "7d", "fable", "claude-zephy", "sonnet"], "shorts")
        t.equal(p.limits.map(\.percent), [12, 45, 8, 0.6, 30], "percents (first scoped duplicate wins)")
        t.near(p.limits[0].resetsAt, Sanitize.isoDateMs("2026-11-17T15:00:00Z") + 412, 1, "session reset with microseconds")
        t.near(p.limits[2].resetsAt, Sanitize.isoDateMs("2026-11-21T00:00:00Z"), 1, "fable reset")
        t.near(p.limits[4].resetsAt, 1795334400 * 1000, 1, "epoch-seconds reset")
        t.check(!p.limits.contains { $0.key.contains("oauth") }, "oauth_apps side bucket skipped")

        let encoded = String(decoding: (try? JSONEncoder().encode(p)) ?? Data(), as: UTF8.self)
        t.check(!encoded.contains(token), "token never in the provider")
    }

    static func utilizationScale(_ t: TestRun) {
        t.equal(ClaudeCollector.utilization(0.6), 0.6, "0.6 is 0.6%")
        t.equal(ClaudeCollector.utilization("45%"), 45, "percent string")
        t.equal(ClaudeCollector.utilization(150), 100, "capped")
        t.equal(ClaudeCollector.utilization(nil), nil, "null dropped")
        t.equal(ClaudeCollector.utilization(-1), nil, "negative dropped")
        t.equal(ClaudeCollector.utilization("abc"), nil, "garbage dropped")
        t.equal(ClaudeCollector.utilization(true), nil, "bool dropped")

        let limits = ClaudeCollector.limits(from: [
            "five_hour": ["utilization": 0.6, "resets_at": NSNull()],
            "seven_day": ["utilization": NSNull()],
        ])
        t.equal(limits.map(\.key), ["session"], "null weekly dropped")
        t.equal(limits.first?.percent ?? -1, 0.6, "fraction not rescaled")
        t.equal(limits.first?.resetsAt ?? -1, 0, "unknown reset")

        // A model holding two windows, plus a monthly one, sorts after weekly.
        let scoped = ClaudeCollector.limits(from: ["limits": [
            ["kind": "monthly_scoped", "percent": 5, "scope": ["model": ["display_name": "Opus 5 (1M context)"]]],
            ["kind": "weekly_scoped", "percent": 7, "scope": ["model": ["display_name": "Opus 5 (1M context)"]]],
            ["kind": "five_hour_scoped", "percent": 9, "scope": ["model": ["display_name": "Opus 5 (1M context)"]]],
        ], "seven_day": ["utilization": 1]])
        t.equal(scoped.map(\.key), ["weekly", "opus-5-1m-context", "opus-5-1m-context-session", "opus-5-1m-context-monthly"], "scoped keys unique + ranked")
        t.equal(scoped.map(\.label), ["Weekly (7-day)", "Opus 5 (1M context) Weekly", "Opus 5 (1M context) Session", "Opus 5 (1M context) Monthly"], "scoped labels")
        t.equal(ClaudeCollector.limits(from: [:]).count, 0, "empty payload")

        // Two kinds landing on one window, and a flat bucket the scoped list
        // already names ("Sonnet 4"), never produce duplicate keys.
        let clash = ClaudeCollector.limits(from: [
            "limits": [
                ["kind": "weekly_scoped", "percent": 3, "scope": ["model": ["display_name": "Sonnet 4"]]],
                ["kind": "seven_day_scoped", "percent": 4, "scope": ["model": ["display_name": "Sonnet 4"]]],
                ["kind": "", "percent": 6, "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "weekly_scoped", "percent": 7, "scope": ["model": ["display_name": "Fable"]]],
            ],
            "seven_day_sonnet": ["utilization": 40],
            "seven_day_haiku": ["utilization": 2],
        ])
        t.equal(clash.map(\.key), ["sonnet-4", "fable", "haiku"], "keys unique, first wins")
        t.equal(clash.map(\.percent), [3, 6, 2], "first window kept")
        t.equal(Set(clash.map(\.key)).count, clash.count, "no duplicate keys")
    }

    static func planLabels(_ t: TestRun) async {
        t.equal(ClaudeCollector.planLabel(tier: "default_claude_max_20x", subscription: "max"), "Max 20x")
        t.equal(ClaudeCollector.planLabel(tier: "default_claude_ai", subscription: "pro"), "Pro")
        t.equal(ClaudeCollector.planLabel(tier: "default_claude_max_5x", subscription: "team"), "Team 5x")
        t.equal(ClaudeCollector.planLabel(tier: "default_claude_max_5x", subscription: ""), "Max 5x")
        t.equal(ClaudeCollector.planLabel(tier: "", subscription: ""), "")

        // The profile's multiplier outranks the credentials'.
        let home = Fixtures.tempHome("claude-profile")
        try? #"{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_20x"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let calls = Calls()
        let collector = ClaudeCollector(credentialReader: creds(expiresIn: -10))
        let p = await collector.collect(context(home, http: stub(calls)))
        t.equal(p.tier, "Max 20x", "profile tier wins")
    }

    // MARK: sign-in states

    static func expired(_ t: TestRun) async {
        let home = Fixtures.tempHome("claude-expired")
        let calls = Calls()
        let p = await ClaudeCollector(credentialReader: creds(expiresIn: -60))
            .collect(context(home, http: stub(calls, body: Fixtures.data("claude/usage.json"))))
        t.equal(calls.all.count, 0, "no probe with an expired token")
        t.equal(p.status, "Sign-in expired", "expired status")
        t.check(p.hint.contains("claude auth login"), "expired hint")
        t.check(p.available, "plan keeps it in the bar")
        t.equal(p.limits.count, 0, "no limits")
        t.equal(p.error, "", "not an error")

        // expiresAt 0 means unknown, not expired.
        let calls2 = Calls()
        let unknown = ClaudeCredentials(accessToken: token, expiresAt: 0, subscriptionType: "pro")
        let p2 = await ClaudeCollector(credentialReader: { _ in unknown })
            .collect(context(home, http: stub(calls2, body: Fixtures.data("claude/usage.json"))))
        t.equal(calls2.all.count, 1, "unknown expiry still probes")
        t.equal(p2.tier, "Pro")

        // A lapsed access token with a live refresh token is only paused.
        let now = Date()
        let paused = ClaudeCredentials(accessToken: token, expiresAt: (now.timeIntervalSince1970 - 60) * 1000,
                                       refreshTokenExpiresAt: (now.timeIntervalSince1970 + 86400) * 1000,
                                       subscriptionType: "max")
        let p3 = await ClaudeCollector(credentialReader: { _ in paused }).collect(context(home, now: now, http: stub(Calls())))
        t.equal(p3.status, "Limits paused", "paused status")
    }

    static func refused(_ t: TestRun) async {
        for status in [401, 403] {
            let calls = Calls()
            let p = await ClaudeCollector(credentialReader: creds())
                .collect(context(Fixtures.tempHome("claude-401"), http: stub(calls, status: status, body: Data(#"{"error":"x"}"#.utf8))))
            t.equal(p.status, "Sign-in expired", "\(status) is sign-in expired")
            t.check(p.hint.contains("claude auth login"), "\(status) hint")
            t.equal(p.error, "", "\(status) is not an error")
            t.check(p.available, "\(status) still available")
            t.equal(p.limits.count, 0)
        }
    }

    static func rateLimitedAndErrors(_ t: TestRun) async {
        let home = Fixtures.tempHome("claude-errors")
        let p = await ClaudeCollector(credentialReader: creds())
            .collect(context(home, http: stub(Calls(), status: 429, headers: ["retry-after": "30"])))
        t.equal(p.error, "rate limited", "429")
        t.check(p.hint.contains("retry after 30s"), "retry-after in hint")
        t.check(p.available, "429 still available")

        let p500 = await ClaudeCollector(credentialReader: creds()).collect(context(home, http: stub(Calls(), status: 500)))
        t.check(p500.error.contains("500"), "500 error")

        let bad = await ClaudeCollector(credentialReader: creds()).collect(context(home, http: stub(Calls(), body: Data("nope".utf8))))
        t.check(!bad.error.isEmpty, "invalid body is an error")

        let empty = await ClaudeCollector(credentialReader: creds()).collect(context(home, http: stub(Calls(), body: Data("{}".utf8))))
        t.check(!empty.error.isEmpty, "no limits is an error")

        let transport = HTTPClient { _, _ in throw HTTPError.transport("offline") }
        let off = await ClaudeCollector(credentialReader: creds()).collect(context(home, http: transport))
        t.check(!off.error.isEmpty, "transport failure is an error")
        t.equal(off.limits.count, 0)
    }

    static func missingCredentials(_ t: TestRun) async {
        let home = Fixtures.tempHome("claude-missing")
        let calls = Calls()
        let p = await ClaudeCollector(credentialReader: { _ in nil }).collect(context(home, http: stub(calls)))
        t.check(!p.available, "no credentials, unavailable")
        t.equal(calls.all.count, 0, "no probe without credentials")
        t.equal(p.limits.count, 0)

        // Credentials without a plan and an expired token: nothing to show.
        let bare = ClaudeCredentials(accessToken: token, expiresAt: 1)
        let p2 = await ClaudeCollector(credentialReader: { _ in bare }).collect(context(home, http: stub(calls)))
        t.check(!p2.available, "no plan and no limits, unavailable")
    }

    static func credentialSources(_ t: TestRun) {
        let older = #"{"claudeAiOauth":{"accessToken":"a-old","expiresAt":1000,"subscriptionType":"pro"}}"#
        let newer = #"{"claudeAiOauth":{"accessToken":"a-new","expiresAt":2000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#
        t.equal(ClaudeCredentials.parse(Data("{}".utf8), source: "x"), nil, "wrong shape")
        t.equal(ClaudeCredentials.parse(Data(newer.utf8), source: "x")?.rateLimitTier ?? "", "default_claude_max_5x")

        // Keychain (stubbed) vs file: later expiresAt wins, both ways.
        let home = Fixtures.tempHome("claude-creds")
        let dir = home.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? older.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let ctx = context(home, http: stub(Calls()))
        let r1 = ClaudeCollector.defaultReader(keychain: { Data(newer.utf8) })(ctx)
        t.equal(r1?.accessToken ?? "", "a-new", "keychain newer wins")
        t.equal(r1?.source ?? "", "keychain")
        try? newer.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let r2 = ClaudeCollector.defaultReader(keychain: { Data(older.utf8) })(ctx)
        t.equal(r2?.accessToken ?? "", "a-new", "file newer wins")
        t.equal(r2?.source ?? "", "credentials-file")
        let r3 = ClaudeCollector.defaultReader(keychain: { nil })(context(Fixtures.tempHome("claude-none"), http: stub(Calls())))
        t.equal(r3, nil, "nothing anywhere")

        // CLAUDE_CONFIG_DIR is respected for the file fallback.
        let alt = Fixtures.tempHome("claude-alt")
        try? older.write(to: alt.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let r4 = ClaudeCollector.defaultReader(keychain: { nil })(
            context(Fixtures.tempHome("claude-home"), http: stub(Calls()), env: ["CLAUDE_CONFIG_DIR": alt.path]))
        t.equal(r4?.accessToken ?? "", "a-old", "CLAUDE_CONFIG_DIR file")
    }

    // MARK: activity

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func user(_ uuid: String, _ at: Date, _ content: Any, extra: [String: Any] = [:]) -> String {
        var e: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": iso(at), "message": ["role": "user", "content": content]]
        e.merge(extra) { $1 }
        return json(e)
    }

    static func assistant(_ uuid: String, _ at: Date, id: String, request: String, input: Int, output: Int,
                          cacheRead: Int = 0, cacheWrite: Int = 0, model: String = "claude-fable-x", sidechain: Bool = false) -> String {
        json(["type": "assistant", "uuid": uuid, "timestamp": iso(at), "requestId": request, "isSidechain": sidechain,
              "message": ["id": id, "role": "assistant", "model": model,
                          "usage": ["input_tokens": input, "output_tokens": output,
                                    "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite]]])
    }

    static func activity(_ t: TestRun) async {
        // Noon local today keeps every offset inside today in any time zone.
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let now = start.addingTimeInterval(12 * 3600)
        let early = start.addingTimeInterval(3600)
        let later = start.addingTimeInterval(11 * 3600)
        let yesterday = start.addingTimeInterval(-3600)

        let home = Fixtures.tempHome("claude-activity")
        let projects = home.appendingPathComponent(".claude/projects")
        let proj = projects.appendingPathComponent("-Users-demo-proj")
        let sub = proj.appendingPathComponent("session-a/subagents")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let main = [
            user("u0", yesterday, "yesterday's prompt"),                                             // not today
            assistant("a0", yesterday, id: "msg_y", request: "req_y", input: 999, output: 999),       // not today
            user("u1", early, "fix the bug"),                                                         // prompt 1
            assistant("a1", early, id: "msg_1", request: "req_1", input: 100, output: 20, cacheRead: 300, cacheWrite: 80),
            assistant("a1b", early, id: "msg_1", request: "req_1", input: 100, output: 20, cacheRead: 300, cacheWrite: 80), // same reply, 2nd block
            user("u2", early, [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]),       // tool result
            user("u3", early, [["type": "text", "text": "and add a test"]]),                          // prompt 2
            user("u4", early, "<command-name>/clear</command-name>"),                                 // local command
            user("u5", early, "<local-command-stdout></local-command-stdout>"),                       // local output
            user("u6", early, "<command-name>/review</command-name>"),                                // custom command: prompt 3
            user("u7", early, "Caveat: ...", extra: ["isMeta": true]),                                // meta
            user("u8", early, "summary", extra: ["isCompactSummary": true]),                          // compaction
            user("u9", early, "[Request interrupted by user]"),                                       // interruption
            assistant("a2", later, id: "msg_2", request: "req_2", input: 10, output: 5),
            assistant("a3", later, id: "msg_s", request: "req_s", input: 1, output: 1, model: "<synthetic>"),
            "not json at all",
            user("u10", later, "/model fable"),                                                      // local command typed raw
        ].joined(separator: "\n") + "\n"
        let mainFile = proj.appendingPathComponent("session-a.jsonl")
        try? main.write(to: mainFile, atomically: true, encoding: .utf8)

        // A resumed copy repeats u1 and msg_1: counted once.
        let resumed = [
            user("u1", early, "fix the bug"),
            assistant("a1", early, id: "msg_1", request: "req_1", input: 100, output: 20, cacheRead: 300, cacheWrite: 80),
            user("u11", later, "next step"),                                                          // prompt 4
        ].joined(separator: "\n")   // no trailing newline
        try? resumed.write(to: proj.appendingPathComponent("session-b.jsonl"), atomically: true, encoding: .utf8)

        // A subagent: its task isn't a typed prompt, its tokens count.
        let agent = [
            user("s1", later, "do the subtask", extra: ["isSidechain": true]),
            assistant("s2", later, id: "msg_a", request: "req_a", input: 7, output: 3, sidechain: true),
        ].joined(separator: "\n") + "\n"
        try? agent.write(to: sub.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

        // A file not modified today is never read, even with today's entries.
        let stale = proj.appendingPathComponent("old.jsonl")
        try? (user("o1", later, "ghost") + "\n").write(to: stale, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: yesterday.addingTimeInterval(-86400)], ofItemAtPath: stale.path)
        // Not a transcript.
        try? (user("x1", later, "ghost") + "\n").write(to: proj.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let a = ClaudeActivity.today(projects: projects, now: now)
        t.equal(a.period, "today")
        t.equal(a.prompts, 4, "typed prompts today, deduplicated")
        // msg_1: 100+20+300+80 = 500, msg_2: 15, msg_a: 10.
        t.equal(a.tokens, 525, "tokens today, deduplicated by message+request")

        // The per-refresh budget: a long line (bigger than one 1 MB chunk) is
        // read across chunks; a budget that ends mid-line stops before it, and
        // the next refresh carries on from there.
        let capHome = Fixtures.tempHome("claude-cap")
        let capDir = capHome.appendingPathComponent("p")
        try? FileManager.default.createDirectory(at: capDir, withIntermediateDirectories: true)
        let long = user("big", early, String(repeating: "x", count: 1_500_000))
        let mid = assistant("m1", early, id: "msg_m", request: "req_m", input: 40, output: 2)
        let last = assistant("m2", later, id: "msg_l", request: "req_l", input: 1000, output: 1)
        try? ([long, mid, last].joined(separator: "\n") + "\n").write(to: capDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let full = ClaudeActivity.today(projects: capDir, now: now)
        t.equal(full.prompts, 1, "long line read across chunks")
        t.equal(full.tokens, 1043, "uncapped tokens")
        let budgeted = ClaudeActivityStore()
        let first = budgeted.scan(projects: capDir, now: now, budget: long.utf8.count + 1 + mid.utf8.count / 2)
        t.equal(first.prompts, 1, "budget: head read")
        t.equal(first.tokens, 0, "budget: partial line not counted")
        let second = budgeted.scan(projects: capDir, now: now)
        t.equal(second, full, "budget: next refresh continues from the offset")

        // Through the collector (CLAUDE_CONFIG_DIR unset → ~/.claude/projects).
        let p = await ClaudeCollector(credentialReader: { _ in nil })
            .collect(context(home, now: now, http: stub(Calls())))
        t.equal(p.activity.prompts, 4, "collector activity prompts")
        t.equal(p.activity.tokens, 525, "collector activity tokens")
        t.equal(p.status, "Waiting for auth", "claude dir present, no login")
        t.check(!p.available, "activity alone doesn't make it available")

        t.equal(ClaudeActivity.today(projects: home.appendingPathComponent("missing"), now: now), Activity(), "no projects dir")
    }

    // MARK: incremental cache

    static func append(_ url: URL, _ lines: [String]) {
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        try? h?.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try? h?.close()
    }

    static func incremental(_ t: TestRun) {
        let start = Calendar.current.startOfDay(for: Date())
        let now = start.addingTimeInterval(12 * 3600)
        let at = start.addingTimeInterval(6 * 3600)
        let home = Fixtures.tempHome("claude-incr")
        let projects = home.appendingPathComponent("projects/p")
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("s.jsonl")
        let cacheURL = home.appendingPathComponent("cache/sub/claude-activity.json")
        let store = ClaudeActivityStore(url: cacheURL)
        let root = home.appendingPathComponent("projects")

        // 1. First read.
        try? ([user("p1", at, "one"), assistant("a1", at, id: "m1", request: "r1", input: 10, output: 1)]
            .joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        var a = store.scan(projects: root, now: now)
        t.equal(a, Activity(period: "today", prompts: 1, tokens: 11), "first scan")
        let offset1 = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0

        // 2. Growth, with dedup across reads (a2 repeats m1/r1, p1 repeats).
        append(file, [assistant("a2", at, id: "m1", request: "r1", input: 10, output: 1),
                      user("p1", at, "one"), user("p2", at, "two"),
                      assistant("a3", at, id: "m2", request: "r2", input: 100, output: 0)])
        a = store.scan(projects: root, now: now)
        t.equal(a, Activity(period: "today", prompts: 2, tokens: 111), "growth deduplicated across reads")
        let cached = (try? JSONDecoder().decode(ClaudeActivityCache.self, from: Data(contentsOf: cacheURL)))
        let size2 = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        t.equal(cached?.files.first(where: { $0.key.hasSuffix("/p/s.jsonl") })?.value.offset ?? -1, size2, "offset at end after growth")
        t.check(size2 > offset1, "file grew")

        // 3. Persistence round-trip: a new store reading the same URL resumes
        //    without reading anything (the file is unreadable now, yet the
        //    counts come back), and the cache holds no prompt text.
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let resumed = ClaudeActivityStore(url: cacheURL).scan(projects: root, now: now)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        t.equal(resumed, a, "persisted cache resumes with no re-read")
        let raw = String(decoding: (try? Data(contentsOf: cacheURL)) ?? Data(), as: UTF8.self)
        t.check(!raw.contains("one") && !raw.contains("\"two\"") && !raw.contains("m1:r1"), "no prompt text or raw ids stored")
        let dirMode = (try? FileManager.default.attributesOfItem(atPath: cacheURL.deletingLastPathComponent().path)[.posixPermissions] as? Int) ?? 0
        t.equal(dirMode, 0o700, "cache dir 0700")

        // 4. Growth is read from the offset, not from 0: rewrite p1's uuid in
        //    place (same length) and append p3. A re-read from 0 would count
        //    "z1" too.
        if let data = try? Data(contentsOf: file), let r = data.range(of: Data(#""uuid":"p1""#.utf8)),
           let h = try? FileHandle(forWritingTo: file) {
            try? h.seek(toOffset: UInt64(r.lowerBound + 8))
            try? h.write(contentsOf: Data("z".utf8))
            try? h.close()
        }
        append(file, [user("p3", at, "three")])
        a = store.scan(projects: root, now: now)
        t.equal(a.prompts, 3, "growth read from the offset only")

        // 5. Truncation → re-read from 0 (counts stay deduplicated).
        try? ([user("p4", at, "four")].joined(separator: "\n") + "\n").write(to: file, atomically: false, encoding: .utf8)
        a = store.scan(projects: root, now: now)
        t.equal(a.prompts, 4, "truncated file re-read from 0")
        t.equal(a.tokens, 111, "earlier replies kept, not double counted")

        // 6. Same size, new mtime → re-read from 0; anonymous lines (no ids)
        //    are counted per file, so a re-read doesn't double them.
        let anon = json(["type": "user", "timestamp": iso(at), "message": ["role": "user", "content": "anon"]])
        try? (anon + "\n").write(to: file, atomically: false, encoding: .utf8)
        _ = store.scan(projects: root, now: now)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: file.path)
        a = store.scan(projects: root, now: now)
        t.equal(a.prompts, 5, "anonymous prompt counted once after mtime-only change")

        // 7. Day rollover: tomorrow starts from an empty cache.
        let tomorrow = now.addingTimeInterval(86400)
        let next = store.scan(projects: root, now: tomorrow)
        t.equal(next, Activity(), "new day resets")
        let reloaded = (try? JSONDecoder().decode(ClaudeActivityCache.self, from: Data(contentsOf: cacheURL)))
        t.check(reloaded?.files.isEmpty ?? false, "yesterday's files dropped")
        t.check(reloaded?.prompts.isEmpty ?? false, "yesterday's dedup state dropped")

        // 8. A trailing line still being written isn't consumed until whole.
        let home2 = Fixtures.tempHome("claude-partial")
        let p2 = home2.appendingPathComponent("p")
        try? FileManager.default.createDirectory(at: p2, withIntermediateDirectories: true)
        let f2 = p2.appendingPathComponent("s.jsonl")
        let whole = user("q1", at, "whole")
        try? (whole + "\n" + String(user("q2", at, "half").prefix(30))).write(to: f2, atomically: true, encoding: .utf8)
        let s2 = ClaudeActivityStore()
        t.equal(s2.scan(projects: p2, now: now).prompts, 1, "partial line waits")
        try? (whole + "\n" + user("q2", at, "half") + "\n").write(to: f2, atomically: false, encoding: .utf8)
        t.equal(s2.scan(projects: p2, now: now).prompts, 2, "completed line read")
    }
}
