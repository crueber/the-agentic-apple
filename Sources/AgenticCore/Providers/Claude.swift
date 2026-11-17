import Foundation

/// Claude Code's OAuth login, as Claude Code stores it. Read-only: the token is
/// only ever sent in the Authorization header of the usage probe, and is never
/// refreshed or written back.
public struct ClaudeCredentials: Sendable, Equatable {
    public var accessToken: String
    /// Epoch ms; 0 when unknown (treated as not expired, as Omarchy does).
    public var expiresAt: Double
    /// Epoch ms; 0 when the store does not say.
    public var refreshTokenExpiresAt: Double
    public var subscriptionType: String
    public var rateLimitTier: String
    /// Where it came from: "keychain" or "credentials-file".
    public var source: String

    public init(accessToken: String, expiresAt: Double = 0, refreshTokenExpiresAt: Double = 0,
                subscriptionType: String = "", rateLimitTier: String = "", source: String = "") {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.source = source
    }

    /// Parse `{"claudeAiOauth": {...}}`. nil when the shape is wrong.
    public static func parse(_ data: Data?, source: String) -> ClaudeCredentials? {
        guard let root = Sanitize.jsonObject(data),
              let login = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return ClaudeCredentials(
            accessToken: (login["accessToken"] as? String) ?? "",
            expiresAt: Sanitize.number(login["expiresAt"]) ?? 0,
            refreshTokenExpiresAt: Sanitize.number(login["refreshTokenExpiresAt"]) ?? 0,
            subscriptionType: Sanitize.text(login["subscriptionType"], max: 60),
            rateLimitTier: Sanitize.text(login["rateLimitTier"], max: 80),
            source: source)
    }

    /// Of two logins, the one with the later expiry.
    public static func newest(_ a: ClaudeCredentials?, _ b: ClaudeCredentials?) -> ClaudeCredentials? {
        guard let a else { return b }
        guard let b else { return a }
        return b.expiresAt > a.expiresAt ? b : a
    }
}

/// Claude collector: plan and limits from Anthropic's OAuth usage endpoint,
/// today's prompts and tokens from Claude Code's transcripts. Ported from
/// Omarchy's `omarchy-agent-usage-claude`.
public struct ClaudeCollector: ProviderCollector {
    public typealias CredentialReader = @Sendable (CollectorContext) -> ClaudeCredentials?

    public static let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
    public static let keychainService = "Claude Code-credentials"

    static let authHelp = "Run `claude auth login` to restore authoritative usage."
    static let expiredHelp = "Claude Code's saved sign-in expired. Start Claude Code, or run `claude auth login`, to refresh it."
    static let pausedHelp = "Claude Code's access token has lapsed. Start Claude Code to refresh it; signing in again is not needed."
    static let unreadable = "Claude credentials could not be read"
    static let refusedHelp = "Anthropic refused Claude Code's sign-in. Start Claude Code, or run `claude auth login`, to sign in again."

    public let credentialReader: CredentialReader
    /// Today's activity cache; persists between refreshes.
    public let activityStore: ClaudeActivityStore

    /// `activityCache`: where to persist the activity scan (nil = in memory only).
    public init(credentialReader: @escaping CredentialReader = ClaudeCollector.defaultReader(),
                activityCache: URL? = nil) {
        self.credentialReader = credentialReader
        self.activityStore = ClaudeActivityStore(url: activityCache)
    }

    public init(credentialReader: @escaping CredentialReader = ClaudeCollector.defaultReader(),
                activityStore: ClaudeActivityStore) {
        self.credentialReader = credentialReader
        self.activityStore = activityStore
    }

    public var id: ProviderID { .claude }

    // MARK: - Credentials

    /// Keychain first, then `<config>/.credentials.json`; the later `expiresAt`
    /// wins. `keychain` is injectable so tests never touch the real Keychain.
    public static func defaultReader(keychain: @escaping @Sendable () -> Data? = readKeychain) -> CredentialReader {
        return { context in
            let fromKeychain = ClaudeCredentials.parse(keychain(), source: "keychain")
            let file = configDir(context).appendingPathComponent(".credentials.json")
            let fromFile = ClaudeCredentials.parse(boundedData(file, max: 256 * 1024), source: "credentials-file")
            return ClaudeCredentials.newest(fromKeychain, fromFile)
        }
    }

    /// `security find-generic-password -w` rather than the Security framework:
    /// the `security` tool's ACL entry survives ad-hoc rebuilds of the app.
    @Sendable public static func readKeychain() -> Data? {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: 15)
        guard r.ok else { return nil }
        let text = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Data(text.utf8)
    }

    /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    static func configDir(_ context: CollectorContext) -> URL {
        if let configured = context.environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty {
            return URL(fileURLWithPath: expand(configured, home: context.home))
        }
        return context.home.appendingPathComponent(".claude")
    }

    static func expand(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    static func boundedData(_ url: URL, max: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= max else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Plan

    /// The CLI's profile: a legacy `.config.json` in the config home, else
    /// `~/.claude.json` for the default home, `<home>/.claude.json` otherwise.
    static func profilePath(_ context: CollectorContext) -> URL {
        let dir = configDir(context)
        let legacy = dir.appendingPathComponent(".config.json")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        let configured = context.environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if configured.isEmpty { return context.home.appendingPathComponent(".claude.json") }
        return dir.appendingPathComponent(".claude.json")
    }

    /// The profile's tier is refreshed against the account; the credentials
    /// keep the tier the token was minted with.
    static func profileTier(_ context: CollectorContext) -> String {
        guard let profile = Sanitize.readJSONFile(profilePath(context)),
              let account = profile["oauthAccount"] as? [String: Any] else { return "" }
        for key in ["userRateLimitTier", "organizationRateLimitTier"] {
            let tier = Sanitize.text(account[key], max: 80)
            if !tier.isEmpty { return tier }
        }
        return ""
    }

    static func multiplier(_ tier: String) -> String? {
        guard let r = tier.range(of: #"max_(\d+x)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(tier[r].dropFirst(4)).lowercased()
    }

    /// Lead with the subscription, keep the multiplier as its qualifier:
    /// "Max 5x", "Pro", "Team 5x".
    public static func planLabel(tier: String, subscription: String) -> String {
        let plan = subscription.isEmpty ? "" : subscription.prefix(1).uppercased() + subscription.dropFirst()
        guard let m = multiplier(tier) else { return plan }
        return (plan.isEmpty ? "Max" : plan) + " " + m
    }

    static func tierLabel(_ creds: ClaudeCredentials, _ context: CollectorContext) -> String {
        var tier = profileTier(context)
        if multiplier(tier) == nil { tier = creds.rateLimitTier }
        return Sanitize.plain(planLabel(tier: tier, subscription: creds.subscriptionType), max: 60)
    }

    // MARK: - Collect

    public func collect(_ context: CollectorContext) async -> Provider {
        var provider = Provider(id: .claude, source: "anthropic-oauth")
        // The Keychain read (`security`) and the transcript scan block; keep
        // them off the cooperative pool.
        let store = activityStore, reader = credentialReader
        let (activity, credentials) = await Blocking.run { () -> (Activity, ClaudeCredentials?) in
            let activity = store.scan(projects: Self.configDir(context).appendingPathComponent("projects"),
                                      now: context.now)
            return (activity, reader(context))
        }
        provider.activity = activity

        guard let creds = credentials else {
            // No login at all: an unused agent unless Claude Code lives here.
            // Then it is a read failure (a locked Keychain after wake, a
            // `security` timeout, a denied prompt): the error lets the merge
            // keep the last good numbers.
            if FileManager.default.fileExists(atPath: Self.configDir(context).path) {
                provider.status = "Waiting for auth"
                provider.hint = Self.authHelp
                provider.error = Self.unreadable
            }
            return provider
        }
        provider.source = "anthropic-oauth (\(creds.source))"
        provider.tier = Self.tierLabel(creds, context)
        provider = await probe(provider, creds, context)
        // A plan with an expired sign-in still belongs in the bar.
        provider.available = !provider.limits.isEmpty || !provider.tier.isEmpty
        return provider
    }

    func probe(_ start: Provider, _ creds: ClaudeCredentials, _ context: CollectorContext) async -> Provider {
        var provider = start
        if creds.accessToken.isEmpty {
            provider.status = "Waiting for auth"
            provider.hint = Self.authHelp
            return provider
        }
        if creds.expiresAt > 0 && creds.expiresAt <= context.nowMs {
            // Never refresh: only Claude Code mints a new token.
            if creds.refreshTokenExpiresAt > context.nowMs {
                provider.status = "Limits paused"
                provider.hint = Self.pausedHelp
            } else {
                provider.status = "Sign-in expired"
                provider.hint = Self.expiredHelp
            }
            return provider
        }

        let headers = [
            "Authorization": "Bearer " + creds.accessToken,
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ]
        let response: HTTPResponse
        do {
            response = try await context.httpClient.get(Self.usageEndpoint, headers)
        } catch {
            provider.error = "Couldn't reach Anthropic's usage endpoint"
            provider.hint = "Retrying shortly. Local Claude Code stats are still shown."
            return provider
        }

        switch response.status {
        case 200..<300: break
        case 401, 403:
            provider.status = "Sign-in expired"
            provider.hint = Self.refusedHelp
            return provider
        case 429:
            provider.error = "rate limited"
            let retry = Sanitize.number(response.headers["retry-after"]).map { " (retry after \(Int($0))s)" } ?? ""
            provider.hint = "Anthropic's usage endpoint is rate limiting checks right now\(retry). Local Claude Code stats are still shown."
            return provider
        default:
            provider.error = "Anthropic's usage endpoint returned status \(response.status)"
            return provider
        }

        guard let payload = response.json else {
            provider.error = "Anthropic's usage endpoint returned an invalid answer"
            return provider
        }
        let limits = Self.limits(from: payload)
        if limits.isEmpty {
            provider.error = "Anthropic's usage endpoint returned no limits"
            provider.status = "Claude limits unavailable"
            return provider
        }
        provider.limits = limits
        provider.readAt = context.nowMs
        return provider
    }

    // MARK: - Limits

    /// A utilization as a percentage (0.6 is 0.6%, as Claude Code's /usage
    /// renders it), capped at 100; nil when missing, negative or non-numeric.
    public static func utilization(_ value: Any?) -> Double? {
        var v = value
        if let s = value as? String { v = s.replacingOccurrences(of: "%", with: "") }
        guard let n = Sanitize.number(v), n >= 0 else { return nil }
        return min(100, n)
    }

    /// "Monthly" / "Weekly" / "Session" from a scoped entry's kind.
    static func scopedWindow(_ kind: String) -> String {
        let k = kind.lowercased()
        if k.contains("month") { return "Monthly" }
        if k.contains("week") || k.contains("day") { return "Weekly" }
        if k.contains("hour") || k.contains("session") { return "Session" }
        return ""
    }

    static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); dash = false }
            else if !dash && !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String((out.isEmpty ? "model" : out).prefix(40))
    }

    /// A model-scoped window: key is the model slug (plus the window when it
    /// isn't weekly, so one model's windows stay apart).
    static func scopedLimit(model: String, window: String, percent: Double, resetsAt: Double) -> Limit {
        let name = Sanitize.plain(model, max: 60)
        let label = window.isEmpty ? name : name + " " + window
        var key = slug(name)
        if !window.isEmpty && window != "Weekly" { key += "-" + window.lowercased() }
        let short = String(name.lowercased().prefix(12))
        return Limit(key: key, label: label, short: short, percent: percent, resetsAt: resetsAt)
    }

    /// Flat buckets that aren't a model's own allowance.
    static let sideBuckets: Set<String> = ["oauth_apps", "cowork", "omelette"]

    /// Sort rank, per the reference's CLAUDE_ORDER: session, weekly,
    /// model-scoped, monthly, other.
    static func rank(_ limit: Limit, scoped: Bool) -> Int {
        if scoped { return limit.label.hasSuffix("Monthly") ? 3 : 2 }
        switch limit.key {
        case "session": return 0
        case "weekly": return 1
        case "monthly": return 3
        default: return 4
        }
    }

    public static func limits(from payload: [String: Any]) -> [Limit] {
        var ranked: [(rank: Int, index: Int, limit: Limit)] = []
        var keys = Set<String>()
        var scopedWeekly: [[Substring]] = []   // slug parts of each scoped weekly window
        func add(_ limit: Limit, scoped: Bool) {
            // Keys stay unique: the first window to claim one keeps it.
            guard keys.insert(limit.key).inserted else { return }
            if scoped && limit.label.hasSuffix(" Weekly") { scopedWeekly.append(limit.key.split(separator: "-")) }
            ranked.append((rank(limit, scoped: scoped), ranked.count, limit))
        }

        if let session = payload["five_hour"] as? [String: Any], let p = utilization(session["utilization"]) {
            add(Limit(key: "session", label: "Session (5-hour)", short: "5h", percent: p,
                      resetsAt: Sanitize.dateMs(session["resets_at"])), scoped: false)
        }
        if let weekly = payload["seven_day"] as? [String: Any], let p = utilization(weekly["utilization"]) {
            add(Limit(key: "weekly", label: "Weekly (7-day)", short: "7d", percent: p,
                      resetsAt: Sanitize.dateMs(weekly["resets_at"])), scoped: false)
        }

        // The `limits` array is where model-scoped allowances live.
        var seen = Set<String>()   // "<model lowercased>|<window>"
        if let entries = payload["limits"] as? [Any] {
            for case let entry as [String: Any] in entries {
                guard let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any] else { continue }
                let display = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (model["id"] as? String) ?? ""
                let name = display.trimmingCharacters(in: .whitespaces)
                let kind = Sanitize.text(entry["kind"], max: 80).trimmingCharacters(in: .whitespaces)
                let window = scopedWindow(kind)
                let dedupe = name.lowercased() + "|" + kind
                guard !name.isEmpty, !seen.contains(dedupe), let p = utilization(entry["percent"]) else { continue }
                seen.insert(dedupe)
                seen.insert(name.lowercased() + "|window:" + window)
                add(scopedLimit(model: name, window: window, percent: p,
                                resetsAt: Sanitize.dateMs(entry["resets_at"])), scoped: true)
            }
        }

        // Legacy flat `seven_day_<model>` buckets, only when non-null and not
        // already covered by the `limits` array.
        for key in payload.keys.sorted() where key.hasPrefix("seven_day_") {
            let model = String(key.dropFirst("seven_day_".count))
            guard !model.isEmpty, !sideBuckets.contains(model),
                  let bucket = payload[key] as? [String: Any],
                  let p = utilization(bucket["utilization"]) else { continue }
            let name = model.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            guard !seen.contains(name.lowercased() + "|window:Weekly") else { continue }
            // "seven_day_sonnet" is the same allowance as a scoped "Sonnet 4 Weekly".
            let tokens = slug(name).split(separator: "-")
            guard !scopedWeekly.contains(where: { parts in tokens.allSatisfy { parts.contains($0) } }) else { continue }
            seen.insert(name.lowercased() + "|window:Weekly")
            add(scopedLimit(model: name, window: "Weekly", percent: p,
                            resetsAt: Sanitize.dateMs(bucket["resets_at"])), scoped: true)
        }

        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }.map(\.limit)
    }
}

// MARK: - Activity

/// Today's prompts and tokens from `~/.claude/projects/**/*.jsonl`.
public enum ClaudeActivity {
    /// Safety valve per refresh; the steady state reads only appended bytes.
    public static let maxBytes = 256 * 1024 * 1024

    /// Claude Code's built-in commands that ask the model nothing (Omarchy's
    /// CLAUDE_CODE_LOCAL_COMMANDS); typing one is not a prompt.
    static let localCommands: Set<String> = [
        "add-dir", "advisor", "agents", "allowed-tools", "android", "app", "artifacts", "autocompact", "autofix-pr",
        "auto-mode-setup", "background", "bashes", "bg", "branch", "break-reminder", "breaks", "brief", "btw", "bug", "cd",
        "checkpoint", "clear", "cloud-plugins", "color", "compact", "config", "context", "copy", "cost", "daemon",
        "design-consent", "design-login", "design-revoke", "desktop", "diff", "downtime", "effort", "exit", "export",
        "extra-usage", "fast", "feedback", "focus", "fork", "goal", "heapdump", "help", "hooks", "ide", "import", "install",
        "install-github-app", "install-slack-app", "ios", "list-agents", "login", "logout", "loops", "marketplace", "mcp",
        "memory", "memory-pause", "mobile", "model", "name", "new", "output-style", "passes", "pause-memory", "peers",
        "permissions", "plan", "plugin", "plugins", "powerup", "privacy-settings", "pro-trial-expired", "quit", "radio",
        "rate-limit-options", "rc", "recap", "reload-plugins", "reload-skills", "remote", "remote-control", "remote-env",
        "rename", "reset", "restart", "resume", "rewind", "scroll-speed", "session", "settings", "setup-bedrock",
        "setup-vertex", "skill-doctor", "skills", "stats", "status", "stickers", "stop", "subtask", "tasks", "teleport",
        "terminal-setup", "theme", "toggle-memory", "tp", "tui", "ultraplan", "ultrareview", "undo", "update", "upgrade",
        "usage", "usage-credits", "version", "voice", "web-setup", "wellbeing", "workflow-launch-exec", "workflows",
    ]

    /// A one-off scan with a fresh in-memory cache.
    public static func today(projects: URL, now: Date, calendar: Calendar = .current, maxBytes: Int = maxBytes) -> Activity {
        ClaudeActivityStore().scan(projects: projects, now: now, calendar: calendar, budget: maxBytes)
    }

    /// A user line a person typed: not a tool result, not meta/caveat lines,
    /// not a subagent's task, not a compaction summary, not a local command.
    static func isTypedPrompt(_ entry: [String: Any]) -> Bool {
        if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true
            || entry["isCompactSummary"] as? Bool == true || entry["toolUseResult"] != nil { return false }
        guard let message = entry["message"] as? [String: Any], (message["role"] as? String ?? "user") == "user" else { return false }
        var text = ""
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [Any] {
            for case let block as [String: Any] in blocks {
                let t = block["type"] as? String ?? ""
                if t == "tool_result" { return false }
                if t == "text", text.isEmpty { text = block["text"] as? String ?? "" }
                if t == "image", text.isEmpty { text = " " }
            }
        } else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        for marker in ["<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
                       "[Request interrupted by user"] where trimmed.hasPrefix(marker) { return false }
        if let open = trimmed.range(of: "<command-name>"), let close = trimmed.range(of: "</command-name>"),
           open.upperBound <= close.lowerBound {
            var name = String(trimmed[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("/") { name.removeFirst() }
            return !localCommands.contains(name.lowercased())
        }
        if trimmed.hasPrefix("/") {
            let name = trimmed.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
            return !localCommands.contains(name.lowercased())
        }
        return true
    }

    struct FileInfo { var url: URL; var size: Int; var mtime: Double; var inode: UInt64 }

    /// `*.jsonl` under `projects` modified since `since`, newest first.
    static func todaysFiles(_ projects: URL, since: Date) -> [FileInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [FileInfo] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 200_000 { break }
            guard url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let mtime = v.contentModificationDate, mtime >= since else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            out.append(FileInfo(url: url, size: v.fileSize ?? 0, mtime: mtime.timeIntervalSince1970, inode: inode))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    /// Stream complete lines from `offset`, reading at most `budget` bytes.
    /// Returns the offset just past the last line handed to `body`, so an
    /// unfinished line (still being written) is read again next time. A
    /// final line without a newline counts only when it is whole JSON.
    static func readLines(_ url: URL, from offset: Int, budget: Int, _ body: (Data) -> Void) -> Int {
        guard budget > 0, let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return offset }
        var consumed = offset        // file offset of buffer's first byte
        var buffer = Data()
        var read = 0
        var skipping = false         // inside a runaway line
        let newline = UInt8(ascii: "\n")
        var atEOF = false
        while read < budget {
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(1 << 20, budget - read)) ?? Data() } catch { break }
            if chunk.isEmpty { atEOF = true; break }
            read += chunk.count
            buffer.append(chunk)
            var start = buffer.startIndex
            while let nl = buffer[start...].firstIndex(of: newline) {
                if skipping { skipping = false } else if nl > start { body(buffer.subdata(in: start..<nl)) }
                start = buffer.index(after: nl)
            }
            consumed += start - buffer.startIndex
            buffer = buffer.subdata(in: start..<buffer.endIndex)
            if buffer.count > 16 * 1024 * 1024 {   // runaway line: drop it
                consumed += buffer.count
                buffer.removeAll()
                skipping = true
            }
        }
        if atEOF && !buffer.isEmpty && !skipping,
           (try? JSONSerialization.jsonObject(with: buffer)) is [String: Any] {
            body(buffer)
            consumed += buffer.count
        }
        return consumed
    }
}

/// The incremental scan's state for one local day. Holds no prompt text:
/// only offsets, counts and 64-bit hashes of entry ids.
public struct ClaudeActivityCache: Codable, Equatable, Sendable {
    public struct FileState: Codable, Equatable, Sendable {
        public var size: Int
        public var mtime: Double
        public var inode: UInt64
        public var offset: Int
        /// Lines without an id can't be deduplicated, so they are kept per
        /// file and dropped when the file is read again from the start.
        public var anonymousPrompts: Int = 0
        public var anonymousTokens: Int = 0
    }

    public static let currentVersion = 1
    /// Bound on each dedup set; ids past it are not counted.
    public static let maxKeys = 400_000

    public var version: Int = currentVersion
    public var day: String
    public var files: [String: FileState] = [:]
    /// Hashes of typed prompts' uuids.
    public var prompts: Set<String> = []
    /// Hash of a reply's message id + request id → its largest token count.
    public var replies: [String: Int] = [:]

    public init(day: String) { self.day = day }

    public var activity: Activity {
        let anonP = files.values.reduce(0) { $0 + $1.anonymousPrompts }
        let anonT = files.values.reduce(0) { $0 + $1.anonymousTokens }
        return Activity(period: "today", prompts: prompts.count + anonP, tokens: replies.values.reduce(anonT, +))
    }

    /// FNV-1a 64, hex.
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Keeps the activity cache between refreshes (in memory, and on disk when
/// given a URL), so each refresh reads only bytes appended since the last.
public final class ClaudeActivityStore: @unchecked Sendable {
    public let url: URL?
    private let lock = NSLock()
    private var cache: ClaudeActivityCache?
    private var loaded = false

    public init(url: URL? = nil) { self.url = url }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func scan(projects: URL, now: Date, calendar: Calendar = .current,
                     budget: Int = ClaudeActivity.maxBytes) -> Activity {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let url, let data = ClaudeCollector.boundedData(url, max: 64 * 1024 * 1024),
               let c = try? JSONDecoder().decode(ClaudeActivityCache.self, from: data),
               c.version == ClaudeActivityCache.currentVersion {
                cache = c
            }
        }
        let day = Self.dayKey(now, calendar)
        var c = (cache?.day == day ? cache : nil) ?? ClaudeActivityCache(day: day)
        let before = cache

        let dayStart = calendar.startOfDay(for: now)
        let startMs = dayStart.timeIntervalSince1970 * 1000
        let endMs = (calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now.addingTimeInterval(86400))
            .timeIntervalSince1970 * 1000
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        func timeMs(_ value: Any?) -> Double {
            guard let s = value as? String else { return Sanitize.dateMs(value) }
            if let d = fractional.date(from: s) ?? whole.date(from: s) { return d.timeIntervalSince1970 * 1000 }
            return Sanitize.dateMs(s)
        }

        let files = ClaudeActivity.todaysFiles(projects, since: dayStart)
        // Files no longer modified today (or gone) leave the cache.
        let present = Set(files.map(\.url.path))
        c.files = c.files.filter { present.contains($0.key) }

        var remaining = budget
        for info in files {
            let path = info.url.path
            var state = c.files[path] ?? .init(size: 0, mtime: 0, inode: info.inode, offset: 0)
            let replaced = state.inode != info.inode || info.size < state.offset
                || (info.size == state.size && info.mtime != state.mtime && state.offset > 0)
            if replaced {
                state = .init(size: 0, mtime: 0, inode: info.inode, offset: 0)
            }
            state.size = info.size
            state.mtime = info.mtime
            if info.size > state.offset && remaining > 0 {
                var anonP = state.anonymousPrompts, anonT = state.anonymousTokens
                let start = state.offset
                state.offset = ClaudeActivity.readLines(info.url, from: start, budget: remaining) { line in
                    guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let type = entry["type"] as? String, type == "user" || type == "assistant" else { return }
                    let ts = timeMs(entry["timestamp"])
                    guard ts >= startMs, ts < endMs else { return }
                    if type == "user" {
                        guard ClaudeActivity.isTypedPrompt(entry) else { return }
                        if let uuid = entry["uuid"] as? String, !uuid.isEmpty {
                            if c.prompts.count < ClaudeActivityCache.maxKeys { c.prompts.insert(ClaudeActivityCache.hash(uuid)) }
                        } else {
                            anonP += 1
                        }
                    } else {
                        guard let message = entry["message"] as? [String: Any],
                              (message["model"] as? String) != "<synthetic>",
                              let usage = message["usage"] as? [String: Any] else { return }
                        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                            .reduce(0) { sum, k in
                                guard let n = Sanitize.number(usage[k]), n >= 0, n < 1e10 else { return sum }
                                return sum + Int(n)
                            }
                        // One reply is written once per content block, each with
                        // the same usage: count it once, keeping the largest copy.
                        let messageID = (message["id"] as? String) ?? ""
                        let requestID = (entry["requestId"] as? String) ?? ""
                        var key = ""
                        if !messageID.isEmpty || !requestID.isEmpty { key = messageID + ":" + requestID }
                        else if let uuid = entry["uuid"] as? String, !uuid.isEmpty { key = "uuid:" + uuid }
                        if key.isEmpty { anonT += tokens; return }
                        let h = ClaudeActivityCache.hash(key)
                        if let old = c.replies[h] { c.replies[h] = max(old, tokens) }
                        else if c.replies.count < ClaudeActivityCache.maxKeys { c.replies[h] = tokens }
                    }
                }
                remaining -= max(0, state.offset - start)
                state.anonymousPrompts = anonP
                state.anonymousTokens = anonT
            }
            c.files[path] = state
        }

        cache = c
        if c != before, let url { Self.save(c, to: url) }
        return c.activity
    }

    /// Atomic write into a 0700 directory, file 0600.
    static func save(_ cache: ClaudeActivityCache, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
