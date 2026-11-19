import Foundation

/// OpenRouter collector, ported from the reference `collectOpenRouter`, plus an
/// account-wide mode for a **management key** (`OpenRouterAccount.swift`).
///
/// Management key (takes precedence when present): `OPENROUTER_MANAGEMENT_KEY`,
/// else the login Keychain item `managementKeyService` / `managementKeyAccount`
/// read through `/usr/bin/security find-generic-password … -w` (injectable as
/// `managementKeyReader`). Then `GET /api/v1/keys` (paginated) and
/// `/api/v1/credits`; the inference key is not resolved at all.
///
/// Inference key (otherwise): `OPENROUTER_API_KEY`, else the `authFile`
/// override (`OPENROUTER_AUTH_FILE` too), else OpenCode's `auth.json`, else
/// `opencode auth export`; then `GET /api/v1/key` and `/api/v1/credits`.
///
/// Either key is used only in an HTTPS `Authorization` header: never logged,
/// cached, returned, or passed on a command line.
///
/// Per-key mode leaves `limits` empty — the Logic layer derives OpenRouter's
/// window from `money` and the previous-cycle history. Account-wide mode adds a
/// `credits` limit and one `key-<hash>` limit per key with a spending limit.
public struct OpenRouterCollector: ProviderCollector {
    /// Returns the raw management key, or nil when there is none; throws when
    /// the store could not be read (e.g. `security` timed out). Tests inject
    /// one; the default reads the Keychain through `/usr/bin/security`.
    public typealias ManagementKeyReader = @Sendable (CollectorContext) throws -> String?

    public let managementKeyReader: ManagementKeyReader
    /// The analytics cost metric and this run's monthly-baseline attempts.
    public let analytics: AnalyticsMemo

    public init(managementKeyReader: @escaping ManagementKeyReader = OpenRouterCollector.defaultManagementKeyReader(),
                analytics: AnalyticsMemo = .shared) {
        self.managementKeyReader = managementKeyReader
        self.analytics = analytics
    }
    public var id: ProviderID { .openrouter }

    public static let keyURL = "https://openrouter.ai/api/v1/key"
    public static let creditsURL = "https://openrouter.ai/api/v1/credits"

    public func collect(_ context: CollectorContext) async -> Provider {
        // A management key covers the whole account and wins over the inference key.
        switch await Self.resolveManagementKey(context, reader: managementKeyReader) {
        case .key(let management):
            return await Self.collectAccount(management, context, analytics: analytics)
        case .unreadable(let message):
            // Don't guess: the merge keeps the last good numbers with this error.
            var provider = Provider(id: .openrouter, source: Self.accountSource)
            provider.error = message
            return provider
        case .none:
            break
        }

        var provider = Provider(id: .openrouter, source: "openrouter-api")

        // `opencode auth export` and file reads block; keep them off the cooperative pool.
        let key = await Blocking.run { Self.resolveKey(context) }
        if key.isEmpty {
            // Not an error (as the reference): a removed key must drop the row,
            // not keep its last numbers forever.
            provider.status = "No key"
            return provider
        }
        provider.available = true

        let http = context.httpClient
        let keyDoc: [String: Any]
        switch await Self.getJSON(Self.keyURL, key: key, http: http) {
        case .failure(let message):
            provider.error = message
            return provider
        case .success(let doc):
            keyDoc = doc
        }
        guard var money = Self.pickMoney(keyDoc) else {
            provider.error = "OpenRouter returned no key data"
            return provider
        }
        // Account credits are optional; the key's own budget is the primary read.
        if case .success(let doc) = await Self.getJSON(Self.creditsURL, key: key, http: http),
           let credits = Self.pickCredits(doc) {
            money.credits = credits.remaining
            money.totalCredits = credits.total
        }
        provider.money = money
        provider.tier = money.label
        provider.status = money.limit != nil ? "Key limit" : "No key limit"
        provider.readAt = context.nowMs
        return provider
    }

    // MARK: - Key resolution

    /// `OPENROUTER_API_KEY`, else an explicit auth file (only that file), else
    /// OpenCode's auth.json, else `opencode auth export`. "" when none.
    static func resolveKey(_ context: CollectorContext) -> String {
        let env = (context.environment["OPENROUTER_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !env.isEmpty { return env }
        let explicit = explicitAuthFile(context)
        if !explicit.isEmpty { return keyFromFile(URL(fileURLWithPath: explicit)) }
        for file in defaultAuthFiles(context) {
            let k = keyFromFile(file)
            if !k.isEmpty { return k }
        }
        return keyFromOpenCodeExport(context)
    }

    static func explicitAuthFile(_ context: CollectorContext) -> String {
        let fromSettings = context.authFile.trimmingCharacters(in: .whitespaces)
        let raw = fromSettings.isEmpty
            ? (context.environment["OPENROUTER_AUTH_FILE"] ?? "").trimmingCharacters(in: .whitespaces)
            : fromSettings
        if raw.isEmpty { return "" }
        if raw == "~" { return context.home.path }
        if raw.hasPrefix("~/") { return context.home.appendingPathComponent(String(raw.dropFirst(2))).path }
        return raw
    }

    /// `$XDG_DATA_HOME/opencode/auth.json` (when set), then `~/.local/share/opencode/auth.json`.
    static func defaultAuthFiles(_ context: CollectorContext) -> [URL] {
        var dirs: [URL] = []
        if let xdg = context.environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            dirs.append(URL(fileURLWithPath: xdg))
        }
        dirs.append(context.home.appendingPathComponent(".local/share"))
        var seen = Set<String>()
        return dirs
            .map { $0.appendingPathComponent("opencode/auth.json") }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func keyFromFile(_ file: URL) -> String {
        guard let doc = Sanitize.readJSONFile(file, maxBytes: 1024 * 1024) else { return "" }
        return keyFromEntry(doc["openrouter"])
    }

    /// `{ key }` or `{ apiKey }` (auth.json entries and export `value`s).
    static func keyFromEntry(_ entry: Any?) -> String {
        guard let entry = entry as? [String: Any] else { return "" }
        for field in ["key", "apiKey"] {
            if let s = entry[field] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    /// OpenCode 2 keeps credentials in SQLite and exposes them through the
    /// documented `opencode auth export [<target>]`. Try the `openrouter`
    /// target first, then every integration. Output stays in memory.
    static func keyFromOpenCodeExport(_ context: CollectorContext) -> String {
        guard let command = context.resolveCommand(context.opencodeCommand, default: "opencode") else { return "" }
        for args in [["auth", "export", "openrouter"], ["auth", "export"]] {
            let r = Shell.run(command, args, environment: context.childEnvironment, timeout: 10)
            guard r.ok, r.stdout.count <= 4 * 1024 * 1024,
                  let doc = try? JSONSerialization.jsonObject(with: r.stdout) else { continue }
            let k = keyFromExport(doc)
            if !k.isEmpty { return k }
        }
        return ""
    }

    /// Accepts the export list (`[{ integrationID, active, value }]`), a single
    /// such item, or an auth.json-style `{ openrouter: { key } }` map.
    static func keyFromExport(_ doc: Any) -> String {
        var items: [[String: Any]] = []
        if let list = doc as? [Any] {
            items = list.compactMap { $0 as? [String: Any] }
        } else if let dict = doc as? [String: Any] {
            if dict["integrationID"] != nil { items = [dict] }
            else { return keyFromEntry(dict["openrouter"]) }
        }
        for item in items {
            guard (item["integrationID"] as? String) == "openrouter" else { continue }
            if let active = item["active"] as? Bool, active == false { continue }
            let k = keyFromEntry(item["value"])
            if !k.isEmpty { return k }
        }
        return ""
    }

    // MARK: - HTTP

    enum Fetch {
        case success([String: Any])
        case failure(String)
    }

    static func getJSON(_ url: String, key: String, http: HTTPClient) async -> Fetch {
        let headers = [
            "Authorization": "Bearer " + key,
            "Accept": "application/json",
            "User-Agent": "the-agentic-apple/1.0",
        ]
        let response: HTTPResponse
        do {
            response = try await http.get(url, headers)
        } catch let e as HTTPError {
            return .failure(scrub(e.description, key: key))
        } catch {
            return .failure("could not read the OpenRouter key")
        }
        let doc = response.json
        if (200..<300).contains(response.status) {
            guard let doc else { return .failure("invalid JSON from OpenRouter") }
            return .success(doc)
        }
        if let err = doc?["error"] as? [String: Any], let message = err["message"] {
            let m = (message as? String) ?? String(describing: message)
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return .failure(scrub(String(t.prefix(240)), key: key)) }
        }
        return .failure("HTTP \(response.status)")
    }

    /// Display-safe error text that can never carry the key.
    static func scrub(_ message: String, key: String) -> String {
        var m = message
        if !key.isEmpty { m = m.replacingOccurrences(of: key, with: "…") }
        let safe = Sanitize.plain(m, max: 240)
        return safe.isEmpty ? "could not read the OpenRouter key" : safe
    }

    // MARK: - Mapping

    /// Never carry a key label beyond a short tail into the UI.
    public static func maskKeyLabel(_ value: Any?) -> String {
        let raw = ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = ""
        for ch in raw.reversed() {
            guard ch.isASCII, ch.isLetter || ch.isNumber else { break }
            tail.insert(ch, at: tail.startIndex)
        }
        return tail.count >= 3 ? "key \u{2026}" + String(tail.suffix(3)) : "OpenRouter key"
    }

    static func source(_ doc: [String: Any]) -> [String: Any] {
        (doc["data"] as? [String: Any]) ?? doc
    }

    /// `/api/v1/key` → Money (credits filled separately).
    static func pickMoney(_ doc: [String: Any]) -> Money? {
        let src = source(doc)
        let eb = src["effective_budget"] as? [String: Any]
        var limit: Double?
        if let l = Sanitize.number(eb?["limit_usd"]), l > 0 { limit = l }
        else if let l = Sanitize.number(src["limit"]), l > 0 { limit = l }

        let intervalRaw = nonEmptyText(eb?["reset_interval"]) ?? nonEmptyText(src["limit_reset"]) ?? "monthly"
        var spend = Sanitize.number(eb?["spend_usd"])
        if spend == nil {
            let interval = intervalRaw.lowercased()
            if interval.contains("week") { spend = Sanitize.number(src["usage_weekly"]) }
            else if interval.contains("day") { spend = Sanitize.number(src["usage_daily"]) }
            else { spend = Sanitize.number(src["usage_monthly"]) ?? Sanitize.number(src["usage"]) }
        }
        return Money(label: maskKeyLabel(src["label"]),
                     limit: limit,
                     spend: spend ?? 0,
                     credits: nil,
                     totalCredits: nil,
                     resetInterval: Sanitize.plain(intervalRaw, max: 40),
                     resetsAt: Sanitize.dateMs(eb?["resets_at"]))
    }

    /// `/api/v1/credits` → total, used, remaining; nil when neither figure is present.
    static func pickCredits(_ doc: [String: Any]) -> (total: Double, used: Double, remaining: Double)? {
        let src = source(doc)
        let total = Sanitize.number(src["total_credits"])
        let used = Sanitize.number(src["total_usage"])
        if total == nil && used == nil { return nil }
        let t = total ?? 0, u = used ?? 0
        return (t, u, max(0, t - u))
    }

    private static func nonEmptyText(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}
