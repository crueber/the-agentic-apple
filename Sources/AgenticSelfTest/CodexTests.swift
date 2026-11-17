import Foundation
import AgenticCore

/// Codex: a fake `codex` app-server (a shell script speaking JSON-RPC lines),
/// a temporary HOME with synthetic ~/.codex files. Fully offline.
enum CodexTests {
    static let now = Date(timeIntervalSince1970: 1_794_916_800) // 2026-11-17T12:00:00Z
    static let fm = FileManager.default
    static let fast = CodexCollector(requestTimeout: 3, accountTimeout: 1)

    struct Setup {
        var home: URL
        var bin: String
        var marker: URL
        var log: URL
    }

    /// A temp HOME with ~/.codex/auth.json (ChatGPT sign-in, synthetic values)
    /// and the fake codex at $HOME/bin/codex.
    static func setup(_ label: String, auth: String? = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"synthetic","access_token":"synthetic","refresh_token":"synthetic","account_id":"acct-demo"}}"#,
                      withBinary: Bool = true) -> Setup {
        let home = Fixtures.tempHome(label)
        let codexHome = home.appendingPathComponent(".codex")
        try? fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        if let auth { try? auth.write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8) }
        let script = String(decoding: Fixtures.data("codex/fake-codex.sh"), as: UTF8.self)
        let bin = withBinary ? Fixtures.fakeBinary(in: home, name: "codex", script: script) : ""
        return Setup(home: home, bin: bin, marker: home.appendingPathComponent("launched"),
                     log: home.appendingPathComponent("rpc.log"))
    }

    static func context(_ s: Setup, response: String = "codex/ratelimits-by-id.json", mode: String = "ok",
                        extraEnv: [String: String] = [:], searchPath: [String]? = nil,
                        codexCommand: String = "") -> CollectorContext {
        var env: [String: String] = [
            "HOME": s.home.path,
            "PATH": "/usr/bin:/bin",
            "FAKE_CODEX_RESPONSE": Fixtures.url(response).path,
            "FAKE_CODEX_MODE": mode,
            "FAKE_CODEX_MARKER": s.marker.path,
            "FAKE_CODEX_LOG": s.log.path,
        ]
        env.merge(extraEnv) { _, new in new }
        return CollectorContext(home: s.home, environment: env,
                                searchPath: searchPath ?? [s.home.appendingPathComponent("bin").path, "/usr/bin", "/bin"],
                                codexCommand: codexCommand, now: now)
    }

    static func launched(_ s: Setup) -> Bool { fm.fileExists(atPath: s.marker.path) }

    static func run(_ t: TestRun) async {
        t.suite("Codex")

        // rateLimitsByLimitId: general windows first, model allowances after, legacy view ignored.
        do {
            let s = setup("codex-byid")
            let p = await fast.collect(context(s))
            t.check(launched(s), "app-server launched")
            t.equal(p.error, "", "no error")
            t.equal(p.hint, "", "no hint when healthy")
            t.equal(p.status, "")
            t.equal(p.available, true)
            t.equal(p.tier, "Plus", "plan name")
            t.near(p.readAt, now.timeIntervalSince1970 * 1000, 1, "readAt = now")
            t.equal(p.limits.map(\.key), ["session", "weekly", "scoped-weekly", "scoped-review"], "keys + order")
            t.equal(p.limits.map(\.label), ["Session (5-hour)", "Weekly (7-day)", "o3 Weekly", "Code review Weekly"], "labels")
            t.equal(p.limits.map(\.short), ["5h", "7d", "7d", "rev"], "shorts")
            if p.limits.count == 4 {
                t.near(p.limits[0].percent, 25)
                t.near(p.limits[0].resetsAt, 1_794_927_600_000, 0.5, "seconds → ms")
                t.near(p.limits[1].percent, 50)
                t.near(p.limits[1].resetsAt, 1_795_132_800_000, 0.5)
                t.near(p.limits[2].percent, 8)
                t.near(p.limits[3].percent, 10)
            }
            let rpcLog = (try? String(contentsOf: s.log, encoding: .utf8)) ?? ""
            t.check(rpcLog.contains("initialized"), "initialized notification sent")
        }

        // Legacy rateLimits only; no planType → account/read fallback; clamp.
        do {
            let s = setup("codex-legacy")
            let p = await fast.collect(context(s, response: "codex/ratelimits-legacy.json"))
            t.equal(p.tier, "Pro 200", "plan from account/read")
            t.equal(p.limits.map(\.key), ["session", "weekly"])
            t.near(p.limits.first?.percent ?? -1, 61.5)
            t.near(p.limits.last?.percent ?? -1, 100, 0.001, "clamped to 100")
        }

        // A Business seat's spend cap without rate windows.
        do {
            let s = setup("codex-spend")
            let p = await fast.collect(context(s, response: "codex/ratelimits-spend.json"))
            t.equal(p.tier, "Business", "team → Business")
            t.equal(p.limits.count, 1)
            t.equal(p.limits.first?.key, "scoped-spend", "reference key for the titled spend row")
            t.equal(p.limits.first?.label, "Spend limit")
            t.equal(p.limits.first?.short, "$")
            t.near(p.limits.first?.percent ?? -1, 25, 0.001, "used / cap")
            t.near(p.limits.first?.resetsAt ?? -1, 1_795_478_400_000, 0.5)
        }

        // An answer without either view of the limits.
        do {
            let s = setup("codex-empty")
            let p = await fast.collect(context(s, response: "codex/ratelimits-empty.json"))
            t.equal(p.available, false)
            t.equal(p.status, "Codex limits unavailable")
            t.check(p.error.contains("without its rate limits"), "error: \(p.error)")
        }

        // Auth error from the server → Waiting for auth + login hint.
        do {
            let s = setup("codex-autherr")
            let p = await fast.collect(context(s, mode: "auth-error"))
            t.equal(p.available, false)
            t.equal(p.status, "Waiting for auth")
            t.equal(p.hint, "Run `codex login` to authenticate.")
            t.equal(p.error, "Codex is not signed in.", "an error, so the merge keeps last-good limits")
        }

        // Another server error → its message (sanitised).
        do {
            let s = setup("codex-othererr")
            let p = await fast.collect(context(s, mode: "other-error"))
            t.equal(p.status, "Codex limits unavailable")
            t.equal(p.error, "internal \u{2039}failure\u{203A}", "message passed through, sanitised")
        }

        // Dead with stderr → its last words; dead and silent → login hint; stall → timeout.
        do {
            let s = setup("codex-die")
            let p = await fast.collect(context(s, mode: "die-stderr"))
            t.check(p.error.hasPrefix("codex app-server exited:"), "stderr surfaced: \(p.error)")
            t.check(p.error.contains("error sending request"), "fatal line kept")

            let q = await fast.collect(context(s, mode: "die-silent"))
            t.equal(q.hint, "Run `codex login` to authenticate.", "silent exit → login hint")
            t.equal(q.status, "Codex limits unavailable")
            t.check(!q.error.isEmpty, "silent exit still carries an error")

            // Exits right after initialize: the `initialized` write meets a closed
            // pipe. Must fail cleanly (no SIGPIPE killing the self-test).
            let e = await fast.collect(context(s, mode: "exit-after-init"))
            t.equal(e.available, false)
            t.equal(e.status, "Codex limits unavailable")
            t.check(!e.error.isEmpty, "early exit reported: \(e.error)")

            let quick = CodexCollector(requestTimeout: 0.6, accountTimeout: 0.3)
            let started = Date()
            let r = await quick.collect(context(s, mode: "stall"))
            t.check(r.error.contains("did not answer account/rateLimits/read"), "stall named: \(r.error)")
            t.check(Date().timeIntervalSince(started) < 5, "bounded by the timeout")
        }

        // No credentials → no launch.
        do {
            let s = setup("codex-noauth", auth: nil)
            let p = await fast.collect(context(s))
            t.check(!launched(s), "no app-server without credentials")
            t.equal(p.available, false)
            t.equal(p.status, "Waiting for auth")
            t.equal(p.error, "Codex is not signed in.")
            t.equal(p.hint, "Run `codex login` to authenticate.")
        }

        // CODEX_ACCESS_TOKEN counts as credentials.
        do {
            let s = setup("codex-envtoken", auth: nil)
            let p = await fast.collect(context(s, extraEnv: ["CODEX_ACCESS_TOKEN": "synthetic"]))
            t.check(launched(s), "launched with an access token in the environment")
            t.equal(p.available, true)
        }

        // A keyring store keeps credentials outside auth.json → launch.
        do {
            let s = setup("codex-keyring", auth: nil)
            try? "# synthetic\nmodel = \"o3\"\ncli_auth_credentials_store = \"keyring\" # os store\n[profiles.x]\ncli_auth_credentials_store = \"file\"\n"
                .write(to: s.home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
            _ = await fast.collect(context(s))
            t.check(launched(s), "keyring store → ask Codex")
        }

        // API-key sign-in → unavailable, no launch.
        do {
            let s = setup("codex-apikey", auth: #"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic"}"#)
            let p = await fast.collect(context(s))
            t.check(!launched(s), "no app-server for an API key")
            t.equal(p.available, false)
            t.equal(p.hint, "Signed in with an API key, which has no plan limits.")
            t.equal(p.error, "")

            let o = setup("codex-apikey-old", auth: #"{"OPENAI_API_KEY":"synthetic","tokens":{"id_token":"synthetic"}}"#)
            _ = await fast.collect(context(o))
            t.check(!launched(o), "older login with a key and no auth_mode is an API-key login")

            let n = setup("codex-apikey-null", auth: #"{"OPENAI_API_KEY":"","tokens":{"id_token":"synthetic"}}"#)
            _ = await fast.collect(context(n))
            t.check(launched(n), "empty key → ChatGPT sign-in")
        }

        // Not in use at all: nothing to say.
        do {
            let home = Fixtures.tempHome("codex-unused")
            let ctx = CollectorContext(home: home, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                                       searchPath: ["/usr/bin", "/bin"], now: now)
            let p = await fast.collect(ctx)
            t.equal(p.available, false)
            t.equal(p.error, "")
            t.equal(p.status, "")
        }

        // ~/.codex exists but no binary anywhere.
        do {
            let s = setup("codex-nobin", withBinary: false)
            let p = await fast.collect(context(s))
            t.equal(p.status, "Codex limits unavailable")
            t.equal(p.error, "codex not found in PATH")
        }

        // mise: a shim (symlink to mise) and a `mise use` launcher on PATH are skipped;
        // `mise which` fails; a real install under installs/codex/<version> is used.
        do {
            let s = setup("codex-mise", withBinary: false)
            let script = String(decoding: Fixtures.data("codex/fake-codex.sh"), as: UTF8.self)
            let tools = s.home.appendingPathComponent("tools")
            let mise = Fixtures.fakeBinary(in: tools, name: "mise",
                                           script: "echo 'mise ERROR No version is set for shim: codex' >&2\nexit 1\n")
            let shims = s.home.appendingPathComponent(".local/share/mise/shims")
            try? fm.createDirectory(at: shims, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: shims.appendingPathComponent("codex").path, withDestinationPath: mise)
            let lazyDir = s.home.appendingPathComponent("lazy")
            Fixtures.fakeBinary(in: lazyDir, name: "codex", script: "mise use -g codex@latest\nexec codex \"$@\"\n")
            let old = s.home.appendingPathComponent(".local/share/mise/installs/codex/0.9.0")
            let new = s.home.appendingPathComponent(".local/share/mise/installs/codex/0.10.1")
            Fixtures.fakeBinary(in: old, name: "codex", script: "exit 9\n")
            Fixtures.fakeBinary(in: new, name: "codex", script: script)
            let path = [shims.path, lazyDir.appendingPathComponent("bin").path, tools.appendingPathComponent("bin").path,
                        "/usr/bin", "/bin"]
            let p = await fast.collect(context(s, searchPath: path))
            t.check(launched(s), "real install launched")
            t.equal(p.available, true, "newest mise install used: \(p.error)")
            t.equal(p.tier, "Plus")
        }

        // npm global inside a mise node version: `bin/codex` → a `#!/usr/bin/env node`
        // script, run by that version's own node (no node anywhere else on PATH).
        do {
            let s = setup("codex-npm-node", withBinary: false)
            let script = String(decoding: Fixtures.data("codex/fake-codex.sh"), as: UTF8.self)
            let nodeRoot = s.home.appendingPathComponent(".local/share/mise/installs/node")
            let version = nodeRoot.appendingPathComponent("26.8.0")
            let pkg = version.appendingPathComponent("lib/node_modules/@openai/codex/bin")
            try? fm.createDirectory(at: pkg, withIntermediateDirectories: true)
            let js = pkg.appendingPathComponent("codex.js")
            try? ("#!/usr/bin/env node\n" + script).write(to: js, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: js.path)
            // A fake `node` that runs the wrapper as a shell script.
            Fixtures.fakeBinary(in: version, name: "node", script: "f=\"$1\"; shift; exec /bin/sh \"$f\" \"$@\"\n")
            try? fm.createSymbolicLink(atPath: version.appendingPathComponent("bin/codex").path,
                                       withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
            try? fm.createDirectory(at: nodeRoot.appendingPathComponent("22.1.0/bin"), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: nodeRoot.appendingPathComponent("latest").path, withDestinationPath: "./22.1.0")
            let p = await fast.collect(context(s, searchPath: ["/usr/bin", "/bin"]))
            t.check(launched(s), "npm codex launched via its own node")
            t.equal(p.available, true, "npm global under mise node: \(p.error)")
        }

        // mise: `mise which codex` resolves an installed binary.
        do {
            let s = setup("codex-misewhich", withBinary: false)
            let script = String(decoding: Fixtures.data("codex/fake-codex.sh"), as: UTF8.self)
            let real = Fixtures.fakeBinary(in: s.home.appendingPathComponent("npm"), name: "codex", script: script)
            let tools = s.home.appendingPathComponent("tools")
            Fixtures.fakeBinary(in: tools, name: "mise",
                                script: "[ \"$1 $2\" = \"which codex\" ] && [ \"$MISE_OFFLINE\" = 1 ] && echo '\(real)' && exit 0\nexit 1\n")
            let p = await fast.collect(context(s, searchPath: [tools.appendingPathComponent("bin").path, "/usr/bin", "/bin"]))
            t.equal(p.available, true, "resolved by mise which: \(p.error)")
        }

        // Explicit override path wins.
        do {
            let s = setup("codex-override", withBinary: false)
            let script = String(decoding: Fixtures.data("codex/fake-codex.sh"), as: UTF8.self)
            let custom = Fixtures.fakeBinary(in: s.home.appendingPathComponent("custom"), name: "codex-cli", script: script)
            let p = await fast.collect(context(s, searchPath: ["/usr/bin", "/bin"], codexCommand: custom))
            t.equal(p.available, true, "override used")
        }
    }
}
