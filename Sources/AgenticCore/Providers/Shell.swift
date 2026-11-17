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

    /// Run `executable` with `arguments`, no shell, stdin closed (or fed `input`),
    /// output bounded, killed after `timeout`.
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String]? = nil,
                           input: Data? = nil,
                           currentDirectory: URL? = nil,
                           timeout: TimeInterval = defaultTimeout) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = inPipe

        let outBox = DataBox(), errBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData, limit: maxOutput) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData, limit: 256 * 1024) }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: -1, stdout: Data(), stderr: Data(), timedOut: false, launched: false)
        }
        if let input { try? inPipe.fileHandleForWriting.write(contentsOf: input) }
        try? inPipe.fileHandleForWriting.close()

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything left after the handlers were removed.
        outBox.append((try? outPipe.fileHandleForReading.readToEnd()) ?? Data(), limit: maxOutput)
        errBox.append((try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), limit: 256 * 1024)
        return CommandResult(status: process.terminationStatus, stdout: outBox.data, stderr: errBox.data,
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

/// GUI apps launched from Finder or at login do not inherit the login shell's
/// PATH, so tools installed by mise, Homebrew or npm would be invisible. This
/// builds the search path once.
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
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__AGENTIC_PATH__"
        let r = Shell.run(shell, ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""],
                          environment: environment, timeout: 6)
        guard r.launched, !r.timedOut else { return [] }
        let text = r.stdoutText
        guard let a = text.range(of: marker), let b = text.range(of: marker, range: a.upperBound..<text.endIndex) else { return [] }
        return text[a.upperBound..<b.lowerBound].split(separator: ":").map(String.init)
    }

    /// Login-shell PATH, then the process PATH, then well-known dirs; de-duplicated.
    public static func resolve(home: URL, environment: [String: String], includeLoginShell: Bool = true) -> [String] {
        var all: [String] = []
        if includeLoginShell { all += loginShellPath(environment: environment) }
        all += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        all += wellKnown(home: home)
        var seen = Set<String>()
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
