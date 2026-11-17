import Foundation
import AgenticCore

/// Shell.run (bounded drain, process groups, timeouts), the login-shell probe
/// (fixture ZDOTDIR, never the real rc files), Blocking, secret redaction and
/// the Codex app-server's process group. All synthetic, all offline.
enum ShellTests {
    static let fm = FileManager.default

    static func run(_ t: TestRun) async {
        t.suite("Shell")
        capture(t)
        grandchildHoldingStdout(t)
        timeoutKillsGroup(t)
        loginSnapshot(t)
        resolveEnvironment(t)
        await blocking(t)
        redaction(t)
        await codexGroup(t)
    }

    static func elapsed(_ start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

    static func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    static func readPid(_ url: URL) -> pid_t {
        let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pid_t(text) ?? 0
    }

    /// Wait (bounded) for a reparented process to be gone.
    static func gone(_ pid: pid_t, within seconds: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while alive(pid), Date() < end { usleep(20_000) }
        return !alive(pid)
    }

    // MARK: capture

    static func capture(_ t: TestRun) {
        let hi = Shell.run("/bin/echo", ["hello"], timeout: 5)
        t.check(hi.ok, "echo ok")
        t.equal(hi.stdoutText, "hello\n")

        let big = Shell.run("/bin/sh", ["-c", "head -c 204800 /dev/zero | tr '\\000' a; echo done >&2"], timeout: 10)
        t.check(big.ok, "200 KB command ok")
        t.equal(big.stdout.count, 204_800, "200 KB fully captured")
        t.check(big.stdout.allSatisfy { $0 == UInt8(ascii: "a") }, "200 KB intact")
        t.equal(big.stderrText, "done\n", "stderr captured")

        let huge = Shell.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero"], timeout: 10)
        t.equal(huge.stdout.count, 3_000_000, "3 MB fully captured")

        let fail = Shell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 7"], timeout: 5)
        t.equal(fail.status, 7, "exit status")
        t.check(!fail.ok, "non-zero is not ok")
        t.equal(fail.stdoutText, "out\n")
        t.equal(fail.stderrText, "err\n")

        let signalled = Shell.run("/bin/sh", ["-c", "kill -9 $$"], timeout: 5)
        t.check(signalled.status != 0 && !signalled.ok, "a signalled child is a failure (\(signalled.status))")

        let fed = Shell.run("/bin/cat", [], input: Data("piped input".utf8), timeout: 5)
        t.equal(fed.stdoutText, "piped input", "input reaches stdin")

        let noStdin = Shell.run("/bin/cat", [], timeout: 5)
        t.check(noStdin.ok && noStdin.stdout.isEmpty, "stdin is /dev/null by default")

        let env = Shell.run("/usr/bin/env", [], environment: ["ONLY_THIS": "1"], timeout: 5)
        t.equal(env.stdoutText, "ONLY_THIS=1\n", "environment replaced, not merged")

        let tmp = Fixtures.tempHome("shell-cwd")
        let cwd = Shell.run("/bin/pwd", [], currentDirectory: tmp, timeout: 5)
        t.check(cwd.stdoutText.trimmingCharacters(in: .newlines).hasSuffix("/" + tmp.lastPathComponent),
                "currentDirectory: \(cwd.stdoutText)")

        let missing = Shell.run("/nonexistent/agentic-tool", [], timeout: 5)
        t.equal(missing.launched, false, "missing executable not launched")
        t.check(!missing.ok, "missing executable not ok")

        // Best of three, so a loaded machine doesn't flake it.
        let fastest = (0..<3).map { _ -> TimeInterval in
            let quick = Date()
            _ = Shell.run("/usr/bin/true", [], timeout: 5)
            return elapsed(quick)
        }.min() ?? 1
        t.check(fastest < 0.2, "a clean exit returns at EOF, without the drain grace (\(fastest))")
    }

    // MARK: grandchild holding stdout (finding: readToEnd blocked until EOF)

    static func grandchildHoldingStdout(_ t: TestRun) {
        let dir = Fixtures.tempHome("shell-gc")
        let pidFile = dir.appendingPathComponent("gc.pid")
        let start = Date()
        let r = Shell.run("/bin/sh", ["-c", "sleep 8 & echo $! > '\(pidFile.path)'; echo hi"], timeout: 2)
        let took = elapsed(start)
        t.check(took < 1.5, "returns right after the child exits, not when the grandchild does (\(took)s)")
        t.check(r.ok, "child's own exit is a success")
        t.equal(r.timedOut, false)
        t.equal(r.stdoutText, "hi\n", "output before the exit captured")
        let gc = readPid(pidFile)
        t.check(alive(gc), "a normal exit leaves the background job alone")
        if gc > 0 { kill(gc, SIGKILL) }

        // A grandchild that keeps writing: still bounded.
        let chatty = Date()
        let w = Shell.run("/bin/sh", ["-c", "(while :; do echo x; sleep 0.05; done) & echo $! > '\(pidFile.path)'; echo first"],
                          timeout: 3)
        t.check(elapsed(chatty) < 1.5, "a chatty grandchild doesn't extend the call (\(elapsed(chatty))s)")
        t.check(w.stdoutText.hasPrefix("first\n") || w.stdoutText.contains("first\n"), "child output kept")
        let loop = readPid(pidFile)
        if loop > 0 { kill(loop, SIGKILL) }
    }

    // MARK: timeout kills the whole group

    static func timeoutKillsGroup(_ t: TestRun) {
        let dir = Fixtures.tempHome("shell-timeout")
        let pidFile = dir.appendingPathComponent("gc.pid")
        let start = Date()
        let r = Shell.run("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; echo partial; sleep 30"], timeout: 1)
        let took = elapsed(start)
        t.equal(r.timedOut, true, "timed out")
        t.check(!r.ok, "timeout is not ok")
        t.check(took < 3, "timeout + grace bounded (\(took)s)")
        t.equal(r.stdoutText, "partial\n", "output before the timeout kept")
        let gc = readPid(pidFile)
        t.check(gc > 0, "grandchild pid recorded")
        t.check(gone(gc), "grandchild killed with the group")

        // A child that ignores SIGTERM still goes (SIGKILL after the grace).
        let stubborn = Date()
        let s = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; while :; do sleep 1; done"],
                          timeout: 0.5)
        t.equal(s.timedOut, true, "stubborn child timed out")
        t.check(elapsed(stubborn) < 3.5, "SIGKILL after the grace (\(elapsed(stubborn))s)")
        t.check(gone(readPid(pidFile)), "stubborn group killed")
    }

    // MARK: login shell probe

    /// A fixture ZDOTDIR and HOME, so the user's real rc files are never read.
    static func zshFixture(_ label: String, zshrc: String) -> (env: [String: String], home: URL) {
        let home = Fixtures.tempHome(label)
        let zdot = home.appendingPathComponent("zdot")
        try? fm.createDirectory(at: zdot, withIntermediateDirectories: true)
        try? zshrc.write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let env = ["SHELL": "/bin/zsh", "HOME": home.path, "ZDOTDIR": zdot.path, "PATH": "/usr/bin:/bin",
                   "TERM": "dumb"]
        return (env, home)
    }

    static func loginSnapshot(_ t: TestRun) {
        // .zshrc (interactive only) adds a PATH dir and exports variables; one
        // value carries a newline and an "=", one is outside the allowlist.
        let rc = """
            echo "rc noise on stdout"
            export PATH="$HOME/fixture-bin:$PATH"
            export CODEX_HOME="$HOME/codex-home"
            export XDG_DATA_HOME="$HOME/xdg data"
            export OPENROUTER_AUTH_FILE=$'line1\\nline2=still'
            export NOT_ALLOWLISTED=synthetic
            export GROK_HOME=""
            """
        let (env, home) = zshFixture("shell-zsh", zshrc: rc)
        let start = Date()
        let snap = SearchPath.loginSnapshot(environment: env)
        let took = elapsed(start)
        t.check(took < 6, "probe within its timeout (\(took)s)")
        t.equal(snap.path.first, home.appendingPathComponent("fixture-bin").path, ".zshrc PATH addition first")
        t.check(snap.path.contains("/usr/bin"), "inherited PATH kept")
        t.equal(snap.environment["CODEX_HOME"], home.appendingPathComponent("codex-home").path)
        t.equal(snap.environment["XDG_DATA_HOME"], home.path + "/xdg data", "spaces survive")
        t.equal(snap.environment["OPENROUTER_AUTH_FILE"], "line1\nline2=still", "newline and = survive")
        t.check(snap.environment["NOT_ALLOWLISTED"] == nil, "only allowlisted variables")
        t.check(snap.environment["PATH"] == nil, "PATH is in .path, not .environment")
        t.check(snap.environment["GROK_HOME"] == nil, "empty values dropped")
        t.equal(SearchPath.loginShellPath(environment: env), snap.path, "loginShellPath is the snapshot's path")

        // A background job started by .zshrc holds the probe's stdout.
        let (bgEnv, bgHome) = zshFixture("shell-zsh-bg", zshrc: """
            export PATH="$HOME/bg-bin:$PATH"
            sleep 10 &!
            """)
        let bgStart = Date()
        let bg = SearchPath.loginSnapshot(environment: bgEnv)
        let bgTook = elapsed(bgStart)
        t.check(bgTook < 3, "background job in .zshrc doesn't hold the probe (\(bgTook)s)")
        t.equal(bg.path.first, bgHome.appendingPathComponent("bg-bin").path, "path read despite the background job")

        // An rc that needs a terminal (reads it, or is stopped by job control)
        // has none: setsid, stdin /dev/null.
        let (ttyEnv, ttyHome) = zshFixture("shell-zsh-tty", zshrc: """
            export PATH="$HOME/tty-bin:$PATH"
            stty -g >/dev/null 2>&1
            read -t 1 line
            [ -t 0 ] && echo "stdin is a tty" >&2
            """)
        let ttyStart = Date()
        let tty = SearchPath.loginSnapshot(environment: ttyEnv)
        t.check(elapsed(ttyStart) < 4, "terminal-touching rc bounded (\(elapsed(ttyStart))s)")
        t.equal(tty.path.first, ttyHome.appendingPathComponent("tty-bin").path, "terminal-touching rc still read")

        // A shell that isn't there: empty, quickly.
        let missing = SearchPath.loginSnapshot(environment: ["SHELL": "/nonexistent/shell"])
        t.equal(missing, LoginShellSnapshot(), "missing shell → empty snapshot")
    }

    static func resolveEnvironment(_ t: TestRun) {
        let (env0, home) = zshFixture("shell-resolve", zshrc: """
            export PATH="$HOME/rc-bin:$PATH"
            export CODEX_HOME="$HOME/from-shell"
            export CLAUDE_CONFIG_DIR="$HOME/claude-from-shell"
            export MISE_DATA_DIR="$HOME/mise"
            """)
        var env = env0
        env["CODEX_HOME"] = "/set/by/launchd"
        env["CLAUDE_CONFIG_DIR"] = ""
        let r = SearchPath.resolveEnvironment(home: home, environment: env)
        t.equal(r.searchPath.first, home.appendingPathComponent("rc-bin").path, "login PATH first")
        t.check(r.searchPath.contains(home.appendingPathComponent(".local/bin").path), "well-known dirs appended")
        t.equal(r.searchPath.count, Set(r.searchPath).count, "de-duplicated")
        t.equal(r.environment["CODEX_HOME"], "/set/by/launchd", "an already-set variable wins")
        t.equal(r.environment["CLAUDE_CONFIG_DIR"], home.path + "/claude-from-shell", "an empty variable counts as unset")
        t.equal(r.environment["MISE_DATA_DIR"], home.path + "/mise", "allowlisted variable imported")
        t.equal(r.environment["ZDOTDIR"], env["ZDOTDIR"], "the rest of the environment kept")
        t.equal(r.environment["PATH"], "/usr/bin:/bin", "PATH itself left to searchPath")
        t.equal(SearchPath.resolve(home: home, environment: env), r.searchPath, "resolve is resolveEnvironment's path")

        let offline = SearchPath.resolveEnvironment(home: home, environment: env, includeLoginShell: false)
        t.equal(offline.searchPath.first, "/usr/bin", "no login shell: process PATH first")
        t.equal(offline.environment, env, "no login shell: environment unchanged")

        t.equal(Set(SearchPath.importedVariables), Set([
            "OPENROUTER_API_KEY", "CODEX_HOME", "CODEX_ACCESS_TOKEN", "CLAUDE_CONFIG_DIR", "XDG_DATA_HOME",
            "XDG_CONFIG_HOME", "MISE_DATA_DIR", "GROK_HOME", "GROK_BOT_HOME", "OPENROUTER_AUTH_FILE",
        ]), "allowlist")
    }

    // MARK: Blocking

    static func blocking(_ t: TestRun) async {
        let value = await Blocking.run { () -> Int in
            Thread.sleep(forTimeInterval: 0.05)
            return 42
        }
        t.equal(value, 42, "Blocking.run returns the work's value")
        async let a = Blocking.run { () -> Bool in Thread.sleep(forTimeInterval: 0.3); return true }
        async let b = Blocking.run { () -> Bool in Thread.sleep(forTimeInterval: 0.3); return true }
        let start = Date()
        let both = await (a, b)
        t.check(both.0 && both.1 && elapsed(start) < 0.55, "blocking work runs in parallel off the pool")
    }

    // MARK: redaction

    static func redaction(_ t: TestRun) {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.c3ludGhldGljLXNpZ25hdHVyZQ"
        let cases: [(String, String)] = [
            ("Authorization: Bearer abc.def-123_synthetic failed", "Bearer"),
            ("token \(jwt) rejected", "eyJ"),
            ("bad key sk-proj-SYNTHETICabcdef0123456789 used", "SYNTHETICabcdef"),
            ("session ZmFrZS1zeW50aGV0aWMtc2VjcmV0LXZhbHVlLTAxMjM0NTY3ODk= expired", "ZmFrZS1"),
            ("access_token=SyntheticValue123 in url", "SyntheticValue123"),
        ]
        for (input, secret) in cases {
            let out = Sanitize.redactSecrets(input)
            if secret == "Bearer" {
                t.check(!out.contains("abc.def-123_synthetic") && out.contains("Bearer …"), "bearer redacted: \(out)")
            } else {
                t.check(!out.contains(secret), "redacted: \(out)")
            }
        }
        let benign = "Error: error sending request for url (https://example.invalid/backend-api/codex/usage)"
        t.equal(Sanitize.redactSecrets(benign), benign, "an ordinary error line survives")
        let path = "failed to read /Users/someone/Library/Application Support/codex/config.toml: not found"
        t.equal(Sanitize.redactSecrets(path), path, "a file path survives")
        for tool in ["~/.local/share/mise/installs/npm-openai-codex/0.46.0/bin/codex",
                     "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"] {
            let line = "spawn \(tool) failed"
            t.equal(Sanitize.redactSecrets(line), line, "a tool path survives")
        }
        let words = "access token has expired, please sign in again"
        t.equal(Sanitize.redactSecrets(words), words, "plain words survive")
    }

    // MARK: Codex app-server process group

    static func codexGroup(_ t: TestRun) async {
        // stderr with a token, then death → the error carries no token.
        do {
            let s = CodexTests.setup("shell-codex-secret")
            Fixtures.fakeBinary(in: s.home, name: "codex", script: """
                read -r line
                echo "fatal: refresh failed for Bearer synthetic-bearer-value-0123456789" >&2
                echo "token eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXN5bnRoZXRpYw leaked" >&2
                exit 1
                """)
            let p = await CodexTests.fast.collect(CodexTests.context(s))
            t.check(p.error.hasPrefix("codex app-server exited:"), "stderr surfaced: \(p.error)")
            t.check(!p.error.contains("synthetic-bearer-value"), "bearer token redacted: \(p.error)")
            t.check(!p.error.contains("eyJhbGci"), "JWT redacted: \(p.error)")
            t.check(p.error.contains("refresh failed"), "the message itself kept")
        }

        // A stalled server with a child of its own: shutdown kills the group.
        do {
            let s = CodexTests.setup("shell-codex-stall")
            let pidFile = s.home.appendingPathComponent("gc.pid")
            Fixtures.fakeBinary(in: s.home, name: "codex", script: """
                sleep 30 &
                echo $! > '\(pidFile.path)'
                while IFS= read -r line; do :; done
                sleep 30
                """)
            let quick = CodexCollector(requestTimeout: 0.5, accountTimeout: 0.3)
            let start = Date()
            let p = await quick.collect(CodexTests.context(s))
            t.check(p.error.contains("did not answer"), "stall reported: \(p.error)")
            t.check(elapsed(start) < 4, "stall bounded (\(elapsed(start))s)")
            let gc = readPid(pidFile)
            t.check(gc > 0, "codex grandchild recorded")
            t.check(gone(gc), "stalled server's child killed with the group")
        }

        // The server dies but its child lives on, holding the pipes: still reaped.
        do {
            let s = CodexTests.setup("shell-codex-orphan")
            let pidFile = s.home.appendingPathComponent("gc.pid")
            Fixtures.fakeBinary(in: s.home, name: "codex", script: """
                sleep 30 &
                echo $! > '\(pidFile.path)'
                read -r line
                exit 0
                """)
            let start = Date()
            let p = await CodexTests.fast.collect(CodexTests.context(s))
            t.check(!p.error.isEmpty, "dead server reported: \(p.error)")
            t.check(elapsed(start) < 5, "orphan case bounded (\(elapsed(start))s)")
            t.check(gone(readPid(pidFile)), "dead server's child killed with the group")
        }
    }
}
