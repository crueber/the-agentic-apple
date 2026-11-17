import Foundation

/// Codex collector: a port of the RPC half of Omarchy's
/// `omarchy-agent-usage-codex` plus the reference plugin's `collectCodex`
/// mapping. Limits and the plan come from the Codex app-server:
/// `codex -s read-only -a on-request app-server`, JSON-RPC lines on stdio,
/// `initialize` → `initialized` → `account/rateLimits/read`.
public struct CodexCollector: ProviderCollector {
    static let authHelp = "Run `codex login` to authenticate."
    static let apiKeyHelp = "Signed in with an API key, which has no plan limits."
    static let unavailable = "Codex limits unavailable"
    static let waitingForAuth = "Waiting for auth"
    /// Every failure carries an `error`, so the merge keeps the last good limits.
    static let notSignedIn = "Codex is not signed in."

    /// Per-request timeout (the reference uses 8 s); tests shorten it.
    let requestTimeout: TimeInterval
    /// The `account/read` plan fallback timeout (2 s in the reference).
    let accountTimeout: TimeInterval

    public init() { self.init(requestTimeout: 8, accountTimeout: 2) }

    /// Shorter timeouts for tests.
    public init(requestTimeout: TimeInterval, accountTimeout: TimeInterval) {
        self.requestTimeout = requestTimeout
        self.accountTimeout = accountTimeout
    }

    public var id: ProviderID { .codex }

    public func collect(_ context: CollectorContext) async -> Provider {
        let requestTimeout = self.requestTimeout, accountTimeout = self.accountTimeout
        // The exchange blocks; keep it off the cooperative pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.collectSync(context, requestTimeout: requestTimeout,
                                                                accountTimeout: accountTimeout))
            }
        }
    }

    // MARK: - Collect

    static func collectSync(_ context: CollectorContext, requestTimeout: TimeInterval,
                            accountTimeout: TimeInterval) -> Provider {
        var provider = Provider(id: .codex, source: "codex-app-server")
        let env = context.environment
        let home = codexHome(context)
        let binary = findCodexBinary(context)

        // Codex is in use here once a binary or launcher is on PATH, its home
        // exists, or a token is handed to it. Otherwise there is nothing to say.
        let inUse = binary != nil
            || Shell.which("codex", searchPath: context.searchPath) != nil
            || FileManager.default.fileExists(atPath: home.path)
            || !(env["CODEX_ACCESS_TOKEN"] ?? "").isEmpty
        guard inUse else { return provider }

        guard let binary else {
            provider.status = unavailable
            provider.error = "codex not found in PATH"
            provider.hint = "Install Codex, or set the path to `codex` in Settings."
            return provider
        }
        // Without credentials account/rateLimits/read can only fail, and starting
        // the app-server is not free (it syncs its plugin list).
        guard hasCodexCredentials(home, env) else {
            provider.status = waitingForAuth
            provider.error = notSignedIn
            provider.hint = authHelp
            return provider
        }
        // An API-key sign-in bills by the token and has no plan limits.
        if apiKeyLogin(home, env) {
            provider.hint = apiKeyHelp
            return provider
        }

        let rpc = fetchRPC(binary: binary, environment: childEnvironment(context, binary: binary),
                           requestTimeout: requestTimeout, accountTimeout: accountTimeout)
        provider.tier = rpc.tier
        provider.status = rpc.status
        provider.hint = rpc.hint
        provider.error = rpc.error
        provider.limits = mapLimits(rpc.limits)
        if rpc.ok { provider.readAt = context.nowMs }
        provider.available = !provider.limits.isEmpty || !provider.tier.isEmpty
        return provider
    }

    // MARK: - Binary discovery (find_codex_binary)

    static func expand(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }

    static func miseDataDir(_ context: CollectorContext) -> String {
        if let d = context.environment["MISE_DATA_DIR"], !d.isEmpty { return expand(d, home: context.home) }
        let data: String
        if let x = context.environment["XDG_DATA_HOME"], !x.isEmpty {
            data = expand(x, home: context.home)
        } else {
            data = context.home.appendingPathComponent(".local/share").path
        }
        return (data as NSString).appendingPathComponent("mise")
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// mise shims and omarchy-style launchers install the tool they wrap when run.
    static func isLazyLauncher(_ path: String, context: CollectorContext) -> Bool {
        let shims = standardized((miseDataDir(context) as NSString).appendingPathComponent("shims"))
        let parent = standardized((path as NSString).deletingLastPathComponent)
        if parent == shims { return true }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path), (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            guard let mise = Shell.which("mise", searchPath: context.searchPath) else { return false }
            return realpath(path) == realpath(mise)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return head.range(of: Data("mise use".utf8)) != nil || head.range(of: Data("mise x ".utf8)) != nil
    }

    static func realpath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func findCodexBinary(_ context: CollectorContext) -> String? {
        // An explicit path from Settings is used as given.
        let override = context.codexCommand.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return context.resolveCommand(override, default: "codex") }

        for dir in context.searchPath where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("codex")
            if isExecutableFile(candidate), !isLazyLauncher(candidate, context: context) { return candidate }
        }
        // `mise which` only prints a binary that is already installed; offline so
        // a configured `latest` is not resolved over the network.
        if let mise = Shell.which("mise", searchPath: context.searchPath) {
            var env = context.childEnvironment
            env["MISE_OFFLINE"] = "1"
            let r = Shell.run(mise, ["which", "codex"], environment: env, timeout: 10)
            let resolved = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok, !resolved.isEmpty, !resolved.contains("\n"), isExecutableFile(resolved),
               !isLazyLauncher(resolved, context: context) {
                return resolved
            }
        }
        // A mise install with no version selected (the shim then refuses to run):
        // look for a real binary under installs/*codex*/<version>/, then for the
        // npm package installed globally into one of mise's node versions.
        let installs = (miseDataDir(context) as NSString).appendingPathComponent("installs")
        let fm = FileManager.default
        let tools = ((try? fm.contentsOfDirectory(atPath: installs)) ?? [])
            .filter { $0.lowercased().contains("codex") }.sorted() + ["node"]
        for tool in tools {
            let toolDir = (installs as NSString).appendingPathComponent(tool)
            for version in installedVersions(toolDir) {
                let base = (toolDir as NSString).appendingPathComponent(version)
                for rel in tool == "node" ? ["bin/codex"] : ["bin/codex", "codex"] {
                    let candidate = (base as NSString).appendingPathComponent(rel)
                    if isExecutableFile(candidate), !isLazyLauncher(candidate, context: context) { return candidate }
                }
            }
        }
        return nil
    }

    /// Real version directories (aliases like `latest` or `22` are symlinks), newest first.
    static func installedVersions(_ toolDir: String) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: toolDir)) ?? [])
            .filter { name in
                guard !name.hasPrefix(".") else { return false }
                let attrs = try? fm.attributesOfItem(atPath: (toolDir as NSString).appendingPathComponent(name))
                return (attrs?[.type] as? FileAttributeType) == .typeDirectory
            }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// The environment the app-server runs in. An npm-installed codex is a
    /// `#!/usr/bin/env node` script: put its own node first on PATH so it does
    /// not depend on a mise node shim having a version set.
    static func childEnvironment(_ context: CollectorContext, binary: String) -> [String: String] {
        var env = context.childEnvironment
        let dir = (binary as NSString).deletingLastPathComponent
        if isExecutableFile((dir as NSString).appendingPathComponent("node")) {
            env["PATH"] = dir + ":" + (env["PATH"] ?? "")
        }
        return env
    }

    // MARK: - Credentials (never reads or keeps a token value)

    static func codexHome(_ context: CollectorContext) -> URL {
        if let h = context.environment["CODEX_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: expand(h, home: context.home))
        }
        return context.home.appendingPathComponent(".codex")
    }

    enum StoreKind { case file, other, unreadable }

    /// `cli_auth_credentials_store` from config.toml's top level (before any table).
    static func credentialStore(_ home: URL) -> StoreKind {
        let url = home.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return .file }
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return .unreadable }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix("cli_auth_credentials_store") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store"
            else { continue }
            let rhs = parts[1].trimmingCharacters(in: .whitespaces)
            var value: String
            if let quote = rhs.first, quote == "\"" || quote == "'" {
                let rest = rhs.dropFirst()
                value = String(rest[..<(rest.firstIndex(of: quote) ?? rest.endIndex)])
            } else {
                value = String(rhs[..<(rhs.firstIndex(of: "#") ?? rhs.endIndex)])
            }
            value = value.trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "file" ? .file : .other
        }
        return .file
    }

    /// has_codex_credentials: keyring/auto stores keep credentials outside auth.json.
    static func hasCodexCredentials(_ home: URL, _ env: [String: String]) -> Bool {
        if !(env["CODEX_ACCESS_TOKEN"] ?? "").isEmpty { return true }
        switch credentialStore(home) {
        case .unreadable, .other: return true
        case .file:
            var isDir: ObjCBool = false
            let path = home.appendingPathComponent("auth.json").path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// api_key_login: auth_mode decides; else any non-empty OPENAI_API_KEY.
    static func apiKeyLogin(_ home: URL, _ env: [String: String]) -> Bool {
        if !(env["CODEX_ACCESS_TOKEN"] ?? "").isEmpty { return false }
        guard credentialStore(home) == .file,
              let auth = Sanitize.readJSONFile(home.appendingPathComponent("auth.json"), maxBytes: 1024 * 1024)
        else { return false }
        if let mode = auth["auth_mode"], !(mode is NSNull) {
            return (mode as? String) == "apikey"
        }
        if let key = auth["OPENAI_API_KEY"] as? String { return !key.isEmpty }
        return false
    }

    // MARK: - RPC

    /// One limit as Omarchy's record carries it (percent already 0…100).
    struct RawLimit: Equatable {
        var label: String
        var percent: Double
        var resetsAt: Double   // epoch ms, 0 when unknown
        var title: String?
    }

    struct RPCResult {
        var ok = false
        var tier = ""
        var status = ""
        var hint = authHelp
        var error = ""
        var limits: [RawLimit] = []
    }

    static func fetchRPC(binary: String, environment: [String: String],
                         requestTimeout: TimeInterval, accountTimeout: TimeInterval) -> RPCResult {
        var result = RPCResult()
        let client: RPCClient
        do {
            client = try RPCClient(executable: binary, arguments: ["-s", "read-only", "-a", "on-request", "app-server"],
                                   environment: environment)
        } catch {
            result.status = unavailable
            result.error = Sanitize.plain("could not start codex: \(error.localizedDescription)", max: 300)
            result.hint = ""
            return result
        }
        defer { client.shutdown() }

        do {
            _ = try client.request(id: 1, method: "initialize",
                                   params: ["clientInfo": ["name": "the-agentic-apple", "version": "1"]],
                                   timeout: requestTimeout)
            try client.send(["method": "initialized", "params": [String: Any]()], operation: "initialized")
            let limitsMessage = try client.request(id: 2, method: "account/rateLimits/read", params: [:],
                                                   timeout: requestTimeout)

            // A home nobody is signed in to answers with an error rather than limits.
            if let error = limitsMessage["error"] as? [String: Any] {
                let message = Sanitize.plain(error["message"], max: 300)
                if message.lowercased().contains("auth") {
                    result.status = waitingForAuth
                    result.error = notSignedIn
                    result.hint = authHelp
                } else {
                    result.status = unavailable
                    result.error = message.isEmpty ? "Codex's app-server refused the request." : message
                    result.hint = ""
                }
                return result
            }
            let rpcResult = limitsMessage["result"] as? [String: Any] ?? [:]
            let buckets = rateLimitBuckets(rpcResult)
            if buckets.isEmpty {
                result.status = unavailable
                result.error = "Codex's app-server answered without its rate limits."
                result.hint = ""
                return result
            }
            result.hint = ""
            var plan = buckets.lazy.compactMap { nonEmpty($0.bucket["planType"]) }.first ?? ""
            if plan.isEmpty, let legacy = rpcResult["rateLimits"] as? [String: Any] {
                plan = nonEmpty(legacy["planType"]) ?? ""
            }
            // The limits name the plan themselves; account/read is only a fallback
            // and never a reason to lose them.
            if plan.isEmpty,
               let account = try? client.request(id: 3, method: "account/read", params: [:], timeout: accountTimeout),
               let acct = (account["result"] as? [String: Any])?["account"] as? [String: Any] {
                plan = nonEmpty(acct["planType"]) ?? nonEmpty(acct["type"]) ?? ""
            }
            result.tier = Sanitize.plain(planName(plan), max: 60)
            result.limits = bucketLimits(buckets)
            if let spend = individualSpendLimit(buckets, rpcResult) { result.limits.append(spend) }
            result.ok = true
        } catch let failure as RPCClient.Failure {
            result.status = unavailable
            let help = rpcHelp(client, failure)
            if help == authHelp {
                // Exited cleanly saying nothing: the typical signed-out shape.
                result.error = "Codex app-server exited without answering."
                result.hint = authHelp
            } else {
                result.error = help
                result.hint = ""
            }
        } catch {
            result.status = unavailable
            result.error = Sanitize.plain(String(describing: error), max: 300)
            result.hint = ""
        }
        return result
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// codex_rpc_help: a live server's stall, a dead one's own stderr, or the
    /// login hint when it died saying nothing.
    static func rpcHelp(_ client: RPCClient, _ failure: RPCClient.Failure) -> String {
        let text = Sanitize.plain(failure.message, max: 300)
        if client.waitForExit(timeout: 1) == false {
            return text.isEmpty ? authHelp : text
        }
        let lines = client.drainedStderr().split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            let joined = lines.joined(separator: " ")
            return Sanitize.plain("codex app-server exited: \(String(joined.suffix(275)))", max: 320)
        }
        return authHelp
    }

    // MARK: - Limits (limit_window, window_title, rate_limit_buckets, bucket_limits, spend_limit)

    static func limitWindow(_ value: Any?) -> (limit: RawLimit, minutes: Double)? {
        guard let window = value as? [String: Any], let used = Sanitize.number(window["usedPercent"])
        else { return nil }
        let mins = Sanitize.number(window["windowDurationMins"]) ?? 0
        let label: String
        if mins == 10080 {
            label = "Weekly (7-day)"
        } else if mins != 0, mins.truncatingRemainder(dividingBy: 60) == 0 {
            label = "\(Int(mins / 60))h window"
        } else if mins != 0 {
            label = mins == mins.rounded() ? "\(Int(mins))m window" : "\(mins)m window"
        } else {
            label = "Limit"
        }
        let reset = Sanitize.number(window["resetsAt"]) ?? 0
        return (RawLimit(label: label, percent: Sanitize.clamp(used, 0, 100),
                         resetsAt: reset > 0 ? (reset * 1000).rounded() : 0, title: nil), mins)
    }

    static func windowTitle(_ minutes: Double) -> String {
        if minutes >= 28 * 24 * 60 { return "Monthly" }
        if minutes >= 24 * 60 { return "Weekly" }
        if minutes > 0 { return "Session" }
        return ""
    }

    /// New app-servers return every metered bucket; `rateLimits` is only the
    /// backward-compatible single-bucket view. Never count both. The general
    /// `codex` bucket goes first, the rest by id (dictionaries are unordered).
    static func rateLimitBuckets(_ result: [String: Any]) -> [(id: String, bucket: [String: Any])] {
        if let byId = result["rateLimitsByLimitId"] as? [String: Any] {
            let entries = byId.compactMap { key, value -> (id: String, bucket: [String: Any])? in
                guard let bucket = value as? [String: Any] else { return nil }
                return (key, bucket)
            }
            if !entries.isEmpty {
                return entries.sorted { a, b in
                    if (a.id == "codex") != (b.id == "codex") { return a.id == "codex" }
                    return a.id < b.id
                }
            }
        }
        if let legacy = result["rateLimits"] as? [String: Any] { return [("codex", legacy)] }
        return []
    }

    static func bucketLimits(_ buckets: [(id: String, bucket: [String: Any])]) -> [RawLimit] {
        var limits: [RawLimit] = []
        for (limitId, bucket) in buckets {
            let limitName = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let general = limitId == "codex" || (buckets.count == 1 && limitName == nil)
            let name = Sanitize.plain(limitName ?? limitId, max: 60).trimmingCharacters(in: .whitespaces)
            for window in [bucket["primary"], bucket["secondary"]] {
                guard var (entry, minutes) = limitWindow(window) else { continue }
                if !general {
                    let span = windowTitle(minutes)
                    entry.title = span.isEmpty ? name : "\(name) \(span)"
                }
                limits.append(entry)
            }
        }
        return limits
    }

    /// A Business seat's spend cap. The amounts give the share; remainingPercent
    /// (whole-percent precision) stands in only for a cap of zero.
    static func spendLimit(_ value: Any?) -> RawLimit? {
        guard let snapshot = value as? [String: Any] else { return nil }
        let share: Double
        if let cap = Sanitize.number(snapshot["limit"]), cap > 0, let used = Sanitize.number(snapshot["used"]) {
            share = used / cap
        } else if let remaining = Sanitize.number(snapshot["remainingPercent"]) {
            share = 1 - remaining / 100
        } else {
            return nil
        }
        let reset = Sanitize.number(snapshot["resetsAt"]) ?? 0
        return RawLimit(label: "Spend limit", percent: Sanitize.clamp(share, 0, 1) * 100,
                        resetsAt: reset > 0 ? (reset * 1000).rounded() : 0, title: "Spend limit")
    }

    /// The cap is the account's: read once, general bucket first, legacy view last.
    static func individualSpendLimit(_ buckets: [(id: String, bucket: [String: Any])],
                                     _ result: [String: Any]) -> RawLimit? {
        let legacy = result["rateLimits"] as? [String: Any] ?? [:]
        for bucket in buckets.map(\.bucket) + [legacy] {
            if let individual = bucket["individualLimit"] as? [String: Any] { return spendLimit(individual) }
        }
        return nil
    }

    /// The plans as Codex's own /status names them, keyed by the wire planType.
    static let planNames: [String: String] = [
        "free": "Free",
        "go": "Go",
        "plus": "Plus",
        "pro": "Pro 200",
        "prolite": "Pro 100",
        "promax": "Pro 500",
        "team": "Business",
        "self_serve_business_usage_based": "Business",
        "self_serve_business_prolite": "Business Premium",
        "business": "Enterprise",
        "enterprise_cbp_automation": "Enterprise (Automation)",
        "enterprise_cbp_usage_based": "Enterprise",
        "ent26": "Enterprise",
        "enterprise": "Enterprise",
        "edu": "Edu",
        "edu_plus": "Edu Plus",
        "edu_pro": "Edu Pro",
    ]

    static func planName(_ plan: String) -> String {
        planNames[plan] ?? plan.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Display mapping (the reference's codexBase / codexLimit / codexRank)

    static let baseOrder: [String: Int] = ["session": 0, "weekly": 1, "review": 2, "spend": 3, "monthly": 4, "other": 5]

    static func base(_ title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("review") { return "review" }
        if lower.contains("session") || lower.contains("5-hour") || lower.contains("5h") || lower.contains("hour window") {
            return "session"
        }
        if lower.contains("week") || lower.contains("7-day") { return "weekly" }
        if lower.contains("month") { return "monthly" }
        if lower.contains("spend") { return "spend" }
        return "other"
    }

    static func displayLimit(_ entry: RawLimit) -> Limit {
        let title = Sanitize.plain(entry.title, max: 80)
        let label = !title.isEmpty ? title : (Sanitize.plain(entry.label, max: 80).isEmpty ? "Limit" : Sanitize.plain(entry.label, max: 80))
        let base = base(label)
        let scoped = !(entry.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let short: String
        switch base {
        case "session": short = "5h"
        case "weekly": short = "7d"
        case "monthly": short = "1m"
        case "review": short = "rev"
        case "spend": short = "$"
        default: short = label.isEmpty ? "limit" : String(label.prefix(6))
        }
        let detail = base == "session" && !scoped ? "Session (5-hour)"
            : base == "weekly" && !scoped ? "Weekly (7-day)"
            : label
        return Limit(key: (scoped ? "scoped-" : "") + base, label: detail, short: short,
                     percent: entry.percent, resetsAt: entry.resetsAt)
    }

    static func rank(_ key: String) -> Int {
        let scoped = key.hasPrefix("scoped-")
        let b = scoped ? String(key.dropFirst(7)) : key
        return (scoped ? 10 : 0) + (baseOrder[b] ?? 9)
    }

    /// Stable sort by rank, ties keep the app-server's order.
    static func mapLimits(_ raw: [RawLimit]) -> [Limit] {
        raw.map(displayLimit).enumerated()
            .sorted { a, b in
                let ra = rank(a.element.key), rb = rank(b.element.key)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}

// MARK: - A small JSON-RPC line client over a long-lived Process

/// Talks newline-delimited JSON-RPC to a child over stdin/stdout. stderr is
/// drained into a bounded buffer (never an unread pipe that could fill).
final class RPCClient: @unchecked Sendable {
    struct Failure: Error { let message: String }

    static let maxPending = 4 * 1024 * 1024

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let condition = NSCondition()
    private var pending = Data()
    private var eof = false
    private var exited = false
    private let stderrBox = DataBox()

    init(executable: String, arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // A child that exits early must not take us down with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.condition.lock()
            if chunk.isEmpty {
                self.eof = true
                handle.readabilityHandler = nil
            } else if self.pending.count < RPCClient.maxPending {
                self.pending.append(chunk)
            }
            self.condition.broadcast()
            self.condition.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self?.stderrBox.append(chunk, limit: 64 * 1024)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            self.exited = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    /// stderr after the child exited: stop the handler, then read what is left,
    /// since the termination and readability callbacks are not ordered.
    func drainedStderr() -> String {
        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = nil
        // Non-blocking: a grandchild that inherited stderr may still hold it open.
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<8 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            stderrBox.append(Data(buffer[0..<n]), limit: 64 * 1024)
        }
        return String(decoding: stderrBox.data, as: UTF8.self)
    }

    /// Write one JSON frame. Throws immediately if the child is gone.
    func send(_ payload: [String: Any], operation: String) throws {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        else { throw Failure(message: "could not encode \(operation)") }
        data.append(0x0A)
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return false }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                left -= n
                p = p.advanced(by: n)
            }
            return true
        }
        if !ok { throw Failure(message: "Codex app-server exited before \(operation)") }
    }

    /// Send a request and wait for the reply with the same id, skipping
    /// notifications and anything unparseable.
    func request(id: Int, method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        try send(["id": id, "method": method, "params": params], operation: method)
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                guard let message = Sanitize.jsonObject(Data(line)) else { continue }
                if let got = Sanitize.number(message["id"]), got == Double(id) { return message }
            }
            if eof || exited {
                // Give a final chunk racing the exit a moment to land.
                if !eof { _ = condition.wait(until: Date().addingTimeInterval(0.1)) }
                if pending.contains(0x0A) { continue }
                throw Failure(message: "Codex app-server exited before \(method)")
            }
            if !condition.wait(until: deadline) {
                if pending.contains(0x0A) { continue }
                throw Failure(message: "Codex app-server did not answer \(method)")
            }
        }
    }

    /// true when the child has exited (within `timeout`).
    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !exited {
            if !condition.wait(until: deadline) { return exited }
        }
        return true
    }

    /// Terminate, wait a second, then SIGKILL.
    func shutdown() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            if !waitForExit(timeout: 1) {
                kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(timeout: 1)
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }
}
