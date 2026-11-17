import Darwin
import Foundation

/// Result of running an external command.
public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var launched: Bool

    public var ok: Bool { launched && !timedOut && status == 0 }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum Shell {
    public static let defaultTimeout: TimeInterval = 25
    public static let maxOutput = 8 * 1024 * 1024
    static let maxStderr = 256 * 1024
    /// After the child exits, how long to wait for its pipes to reach EOF. A
    /// grandchild that inherited stdout may hold them open indefinitely.
    static let drainGrace: TimeInterval = 0.25
    /// On timeout, SIGTERM the group, wait this long, then SIGKILL it.
    static let termGrace: TimeInterval = 1

    /// Find an executable. An absolute/relative path containing "/" is used as-is
    /// when executable; otherwise each directory in `searchPath` is tried.
    public static func which(_ command: String, searchPath: [String]) -> String? {
        let fm = FileManager.default
        if command.isEmpty { return nil }
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in searchPath where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(command)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Run `executable` with `arguments`: no shell, stdin `/dev/null` (or fed
    /// `input`), output bounded, the whole call bounded by `timeout`.
    ///
    /// The child gets its own process group (`newSession`: its own session, so
    /// no controlling terminal either). On timeout the whole group gets SIGTERM,
    /// then SIGKILL. After a normal exit, pipes still held open by a background
    /// grandchild are drained for at most `drainGrace`, never waited on.
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String]? = nil,
                           input: Data? = nil,
                           currentDirectory: URL? = nil,
                           timeout: TimeInterval = defaultTimeout,
                           newSession: Bool = false) -> CommandResult {
        let notLaunched = CommandResult(status: -1, stdout: Data(), stderr: Data(), timedOut: false, launched: false)
        guard let out = Spawn.pipe() else { return notLaunched }
        guard let err = Spawn.pipe() else { Spawn.close(out); return notLaunched }
        var inPipe: (read: Int32, write: Int32)?
        if input != nil {
            guard let p = Spawn.pipe() else { Spawn.close(out); Spawn.close(err); return notLaunched }
            inPipe = p
        }

        let pid: pid_t
        do {
            pid = try Spawn.spawn(executable, arguments, environment: environment,
                                  stdin: inPipe?.read, stdout: out.write, stderr: err.write,
                                  currentDirectory: currentDirectory, newSession: newSession)
        } catch {
            Spawn.close(out); Spawn.close(err)
            if let inPipe { Spawn.close(inPipe) }
            return notLaunched
        }
        // The child has its copies; ours would keep the pipes from reaching EOF.
        Darwin.close(out.write); Darwin.close(err.write)
        if let inPipe { Darwin.close(inPipe.read) }
        Spawn.setNonBlocking(out.read); Spawn.setNonBlocking(err.read)

        var stdinFd: Int32 = -1
        var pendingInput = input ?? Data()
        if let inPipe {
            stdinFd = inPipe.write
            Spawn.setNonBlocking(stdinFd)
            _ = fcntl(stdinFd, F_SETNOSIGPIPE, 1)
            if pendingInput.isEmpty { Darwin.close(stdinFd); stdinFd = -1 }
        }

        var stdout = Data(), stderr = Data()
        var outFd = out.read, errFd = err.read
        let deadline = Spawn.monotonic() + max(0, timeout)
        var exitedAt: TimeInterval?
        var waitStatus: Int32 = 0
        var timedOut = false

        func closeInput() { if stdinFd >= 0 { Darwin.close(stdinFd); stdinFd = -1 } }

        /// One poll pass over the open pipes; reads what is ready.
        func pump(_ waitSeconds: TimeInterval) {
            var fds: [pollfd] = []
            if outFd >= 0 { fds.append(pollfd(fd: outFd, events: Int16(POLLIN), revents: 0)) }
            if errFd >= 0 { fds.append(pollfd(fd: errFd, events: Int16(POLLIN), revents: 0)) }
            if stdinFd >= 0 { fds.append(pollfd(fd: stdinFd, events: Int16(POLLOUT), revents: 0)) }
            let ms = Int32(max(0, min(waitSeconds, 0.05)) * 1000)
            if fds.isEmpty {
                // Pipes done, child not reaped yet: check again shortly.
                usleep(useconds_t(max(0, min(waitSeconds, 0.005)) * 1_000_000))
                return
            }
            let n = poll(&fds, nfds_t(fds.count), ms)
            if n <= 0 { return }
            for p in fds where p.revents != 0 {
                if p.fd == outFd {
                    if !Spawn.drain(outFd, into: &stdout, limit: maxOutput) { Darwin.close(outFd); outFd = -1 }
                } else if p.fd == errFd {
                    if !Spawn.drain(errFd, into: &stderr, limit: maxStderr) { Darwin.close(errFd); errFd = -1 }
                } else if p.fd == stdinFd {
                    if p.revents & Int16(POLLOUT) != 0 {
                        let written = pendingInput.withUnsafeBytes { Darwin.write(stdinFd, $0.baseAddress, $0.count) }
                        if written > 0 { pendingInput.removeFirst(written) }
                        if (written < 0 && errno != EAGAIN && errno != EINTR) || pendingInput.isEmpty { closeInput() }
                    } else {
                        closeInput()   // POLLERR / POLLHUP: the child closed its stdin.
                    }
                }
            }
        }

        while true {
            let now = Spawn.monotonic()
            if exitedAt == nil, Spawn.reap(pid, &waitStatus, block: false) { exitedAt = now }
            if let exitedAt {
                closeInput()
                let drainUntil = min(exitedAt + drainGrace, deadline)
                if (outFd < 0 && errFd < 0) || now >= drainUntil { break }
                pump(drainUntil - now)
            } else {
                if now >= deadline { timedOut = true; break }
                pump(deadline - now)
            }
        }

        if timedOut {
            closeInput()
            // The leader is not reaped yet, so its pid still names the group.
            kill(-pid, SIGTERM)
            kill(-pid, SIGCONT)   // a job-control-stopped child only sees TERM once continued
            let graceEnd = Spawn.monotonic() + termGrace
            while !Spawn.hasExited(pid), Spawn.monotonic() < graceEnd { pump(0.02) }
            kill(-pid, SIGKILL)
            let killEnd = Spawn.monotonic() + 2
            while !Spawn.reap(pid, &waitStatus, block: false), Spawn.monotonic() < killEnd { usleep(10_000) }
        }
        if outFd >= 0 { Darwin.close(outFd) }
        if errFd >= 0 { Darwin.close(errFd) }
        return CommandResult(status: Spawn.exitCode(waitStatus), stdout: stdout, stderr: stderr,
                             timedOut: timedOut, launched: true)
    }

    /// Run and parse stdout as a JSON object.
    public static func runJSON(_ executable: String, _ arguments: [String],
                               environment: [String: String]? = nil,
                               timeout: TimeInterval = defaultTimeout) -> [String: Any]? {
        let r = run(executable, arguments, environment: environment, timeout: timeout)
        guard r.ok else { return nil }
        return Sanitize.jsonObject(r.stdout)
    }
}

/// `posix_spawn` with the pieces `Foundation.Process` cannot do: a new
/// process group or session, signal defaults, and no inherited descriptors
/// beyond stdio (collectors spawn concurrently; a sibling holding another
/// child's pipe would keep it from reaching EOF).
enum Spawn {
    struct Failure: Error { let code: Int32 }

    /// A close-on-exec pipe, or nil.
    static func pipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard Darwin.pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    static func close(_ p: (read: Int32, write: Int32)) {
        Darwin.close(p.read); Darwin.close(p.write)
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func monotonic() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// Start `executable`. `stdin` nil means `/dev/null`. The child leads a new
    /// process group (`newSession`: a new session without a controlling terminal).
    static func spawn(_ executable: String, _ arguments: [String], environment: [String: String]?,
                      stdin: Int32?, stdout: Int32, stderr: Int32,
                      currentDirectory: URL? = nil, newSession: Bool = false) throws -> pid_t {
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if newSession {
            flags |= Int32(POSIX_SPAWN_SETSID)   // also a new group, led by the child
        } else {
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attr, 0)
        }
        posix_spawnattr_setflags(&attr, Int16(flags))
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?]?
        if let environment {
            envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        }
        defer { envp?.forEach { free($0) } }

        var pid: pid_t = 0
        let rc: Int32
        if var envp {
            rc = posix_spawn(&pid, executable, &actions, &attr, argv, &envp)
        } else {
            rc = posix_spawn(&pid, executable, &actions, &attr, argv, environ)
        }
        guard rc == 0 else { throw Failure(code: rc) }
        return pid
    }

    /// Read everything ready on a non-blocking fd. false at EOF (or a hard error).
    /// Past `limit` the bytes are read and dropped, so the writer never blocks.
    static func drain(_ fd: Int32, into data: inout Data, limit: Int) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<64 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                if data.count < limit { data.append(contentsOf: buffer[0..<min(n, limit - data.count)]) }
                continue
            }
            if n == 0 { return false }
            if errno == EINTR { continue }
            return errno == EAGAIN
        }
        return true
    }

    /// true once `pid` has exited, without reaping it (its pid, and so its
    /// process group id, stays reserved until `reap`).
    static func hasExited(_ pid: pid_t, block: Bool = false) -> Bool {
        var info = siginfo_t()
        while true {
            let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | (block ? 0 : WNOHANG))
            if rc == 0 { return info.si_pid == pid }
            if errno == EINTR { continue }
            return errno == ECHILD
        }
    }

    /// Reap `pid`; true when it was reaped (`status` set).
    static func reap(_ pid: pid_t, _ status: inout Int32, block: Bool) -> Bool {
        while true {
            let rc = waitpid(pid, &status, block ? 0 : WNOHANG)
            if rc == pid { return true }
            if rc < 0 && errno == EINTR { continue }
            return false
        }
    }

    /// An exit code from a wait status; a signal gives 128 + its number.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !d.isEmpty, storage.count < limit else { return }
        storage.append(d.prefix(limit - storage.count))
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Blocking work (processes, file scans, the Keychain) moved off Swift's
/// cooperative pool, which must never wait on I/O.
public enum Blocking {
    public static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// What one login-shell probe reported: its PATH and the allowlisted variables.
public struct LoginShellSnapshot: Sendable, Equatable {
    public var path: [String]
    public var environment: [String: String]

    public init(path: [String] = [], environment: [String: String] = [:]) {
        self.path = path
        self.environment = environment
    }
}

/// GUI apps launched from Finder or at login do not inherit the login shell's
/// environment, so tools installed by mise, Homebrew or npm would be invisible
/// and variables set in `~/.zshrc` missing. This asks the shell once.
public enum SearchPath {
    /// Well-known locations, appended after the login-shell PATH.
    public static func wellKnown(home: URL) -> [String] {
        let h = home.path
        return [
            "\(h)/.local/bin",
            "\(h)/.local/share/mise/shims",
            "\(h)/.bun/bin",
            "\(h)/.npm-global/bin",
            "\(h)/.opencode/bin",
            "\(h)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    /// Ask the user's login shell for its PATH (bounded by a timeout).
    public static func loginShellPath(environment: [String: String]) -> [String] {
        loginSnapshot(environment: environment).path
    }

    /// Login-shell PATH, then the process PATH, then well-known dirs; de-duplicated.
    public static func resolve(home: URL, environment: [String: String], includeLoginShell: Bool = true) -> [String] {
        resolveEnvironment(home: home, environment: environment, includeLoginShell: includeLoginShell).searchPath
    }
}

extension SearchPath {
    /// Variables a collector reads that users commonly set in their shell rc.
    public static let importedVariables: [String] = [
        "OPENROUTER_API_KEY", "OPENROUTER_AUTH_FILE",
        "CODEX_HOME", "CODEX_ACCESS_TOKEN",
        "CLAUDE_CONFIG_DIR",
        "XDG_DATA_HOME", "XDG_CONFIG_HOME",
        "MISE_DATA_DIR",
        "GROK_HOME", "GROK_BOT_HOME",
    ]

    static let beginMarker = "__AGENTIC_ENV_BEGIN__"
    static let endMarker = "__AGENTIC_ENV_END__"
    static let probeTimeout: TimeInterval = 6

    /// The probe: absolute tools only, so it reads the same in zsh, bash and
    /// fish. Every record is NUL-terminated, so no value can break the parse.
    /// Should `env -0` be unsupported, PATH alone is still reported.
    static var probeScript: String {
        "/usr/bin/printf '\\0%s\\0' \(beginMarker); /usr/bin/env -0 || /usr/bin/printf 'PATH=%s\\0' \"$PATH\"; /usr/bin/printf '\\0%s\\0' \(endMarker)"
    }

    /// One login-shell probe: its PATH and the allowlisted variables.
    ///
    /// `$SHELL -l -i -c` (interactive, so `.zshrc` additions such as
    /// `mise activate` count) in a new session with no controlling terminal and
    /// stdin from `/dev/null`: job control can never stop it, and a background
    /// job the rc starts cannot hold the probe past its timeout. Values are
    /// never logged. Any failure is an empty snapshot.
    public static func loginSnapshot(environment: [String: String]) -> LoginShellSnapshot {
        loginSnapshot(environment: environment, timeout: probeTimeout)
    }

    static func loginSnapshot(environment: [String: String], timeout: TimeInterval) -> LoginShellSnapshot {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let r = Shell.run(shell, ["-l", "-i", "-c", probeScript],
                          environment: environment, timeout: timeout, newSession: true)
        guard r.launched, !r.timedOut else { return LoginShellSnapshot() }
        return parseSnapshot(r.stdout)
    }

    /// The records between the last begin/end marker pair (rc noise may come first).
    static func parseSnapshot(_ data: Data) -> LoginShellSnapshot {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let end = records.lastIndex(of: endMarker),
              let begin = records[..<end].lastIndex(of: beginMarker) else { return LoginShellSnapshot() }
        let wanted = Set(importedVariables + ["PATH"])
        var vars: [String: String] = [:]
        for record in records[(begin + 1)..<end] {
            guard let eq = record.firstIndex(of: "=") else { continue }
            let name = String(record[..<eq])
            guard wanted.contains(name) else { continue }
            vars[name] = String(record[record.index(after: eq)...])
        }
        let path = (vars.removeValue(forKey: "PATH") ?? "").split(separator: ":").map(String.init)
        return LoginShellSnapshot(path: path, environment: vars.filter { !$0.value.isEmpty })
    }

    /// Merge: login-shell PATH, process PATH, well-known dirs (as `resolve` does), and allowlisted vars
    /// (a variable already set in `environment` wins over the shell's).
    public static func resolveEnvironment(home: URL, environment: [String: String],
                                          includeLoginShell: Bool = true) -> (searchPath: [String], environment: [String: String]) {
        let snapshot = includeLoginShell ? loginSnapshot(environment: environment) : LoginShellSnapshot()
        return merge(snapshot, home: home, environment: environment)
    }

    /// The pure half of `resolveEnvironment`. An empty variable counts as unset.
    static func merge(_ snapshot: LoginShellSnapshot, home: URL,
                      environment: [String: String]) -> (searchPath: [String], environment: [String: String]) {
        var all = snapshot.path
        all += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        all += wellKnown(home: home)
        var seen = Set<String>()
        let searchPath = all.filter { !$0.isEmpty && seen.insert($0).inserted }

        var env = environment
        for name in importedVariables {
            guard let value = snapshot.environment[name], !value.isEmpty,
                  (env[name] ?? "").isEmpty else { continue }
            env[name] = value
        }
        return (searchPath, env)
    }
}
