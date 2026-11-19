import Foundation

/// OpenRouter's account-wide mode: a **management key** (created at
/// openrouter.ai/settings/management-keys) can read every key's usage and the
/// account's credits, which an inference key cannot.
///
/// Sources, in order:
/// - `OPENROUTER_MANAGEMENT_KEY` (imported from the login shell), else
/// - the login Keychain generic password `managementKeyService` /
///   `managementKeyAccount`, read with `/usr/bin/security find-generic-password
///   -s <service> -a default -w` (the key arrives on stdout, never on argv).
///   The app writes that item from Settings (Security framework, with an access
///   list trusting the app and `/usr/bin/security`).
///
/// Endpoints (`Authorization: Bearer <management key>` only):
/// - `GET /api/v1/keys?offset=N` — enabled, non-expired keys, 100 per page,
///   at most `maxKeyPages` pages.
/// - `GET /api/v1/credits` — `total_credits`, `total_usage` (USD).
///
/// Mapping:
/// - money: label `Money.accountWideLabel` ("All keys"), spend = Σ `usage_monthly`,
///   no limit, monthly, resets the next 1st 00:00 UTC; credits left / total.
/// - limits: `credits` (used / purchased), then up to `maxKeyRows` keys with a
///   spending limit (`key-<first 8 of hash>`), highest percent first.
/// - Failures never fall back to the inference key; they set `error` and return
///   no numbers, so `ProviderMerge` keeps the last good ones.
///
/// Public API:
/// - `managementKeyService`, `managementKeyAccount`, `managementKeyEnv`, `keysURL`,
///   `managementKeysPage`, `accountSource`
/// - `normalizedManagementKey(_:) -> String?`, `managementKeyProblem(_:) -> String?`
/// - `readManagementKeyFromKeychain(_:) throws -> String?` (throws only when `security` can't answer)
/// - `verifyManagementKey(_:http:) async -> (ok: Bool, message: String)` (Settings › Save)
/// - `nextReset(_ interval: String?, now: Date) -> Double`, `nextDailyReset`,
///   `nextWeeklyReset`, `nextMonthlyReset` (epoch ms, UTC, strictly after `now`)
extension OpenRouterCollector {
    public static let managementKeyService = "com.crueber.agentic-apple.openrouter-management-key"
    public static let managementKeyAccount = "default"
    public static let managementKeyEnv = "OPENROUTER_MANAGEMENT_KEY"
    public static let keysURL = "https://openrouter.ai/api/v1/keys"
    public static let managementKeysPage = "https://openrouter.ai/settings/management-keys"
    public static let accountSource = "openrouter-management"
    public static let accountTier = "Management key"

    static let keysPageSize = 100
    static let maxKeyPages = 10
    static let maxKeyRows = 6
    static let managementKeyMinLength = 16
    static let managementKeyMaxLength = 512

    static let expiredStatus = "Management key expired or invalid"
    static let expiredHint = "Create a new one at openrouter.ai/settings/management-keys and save it in Settings"
    static let noFallbackNote = "The inference key isn't used while a management key is set."

    // MARK: - Key

    /// Trimmed key when it has a plausible shape (no inner whitespace or control
    /// characters, printable ASCII, sane length), else nil.
    public static func normalizedManagementKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return managementKeyProblem(key) == nil ? key : nil
    }

    /// Why a (trimmed) key is rejected, or nil when it looks fine. Never echoes the key.
    public static func managementKeyProblem(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "Paste a management key first" }
        if key.unicodeScalars.contains(where: { !$0.isASCII || $0.value <= 0x20 || $0.value == 0x7F }) {
            return "A key has no spaces or special characters"
        }
        if key.count < managementKeyMinLength { return "That looks too short for an OpenRouter key" }
        if key.count > managementKeyMaxLength { return "That looks too long for an OpenRouter key" }
        return nil
    }

    /// `security` rather than the Security framework: the app is ad-hoc signed,
    /// so its identity changes with every update, while `/usr/bin/security` —
    /// trusted in the item's access list — does not. The key comes back on
    /// stdout only; the command line carries the service and account names.
    /// A missing item (any non-zero exit) is "no key"; only a `security` that
    /// could not run or did not answer in time throws, so a stuck Keychain
    /// keeps the last numbers instead of switching views.
    @Sendable public static func readManagementKeyFromKeychain(_ context: CollectorContext) throws -> String? {
        let r = Shell.run("/usr/bin/security",
                          ["find-generic-password", "-s", managementKeyService, "-a", managementKeyAccount, "-w"],
                          timeout: 10)
        if r.timedOut || !r.launched { throw KeychainUnreadable() }
        guard r.ok, r.stdout.count <= 4096 else { return nil }
        return normalizedManagementKey(r.stdoutText)
    }

    struct KeychainUnreadable: Error {}

    static let unreadableKeychain = "The OpenRouter management key could not be read from the Keychain"

    enum ManagementKeyLookup { case key(String), none, unreadable }

    /// The environment first (no process spawned), then the injected reader.
    static func resolveManagementKey(_ context: CollectorContext, reader: @escaping ManagementKeyReader) async -> ManagementKeyLookup {
        if let env = normalizedManagementKey(context.environment[managementKeyEnv]) { return .key(env) }
        // `try?` would flatten "threw" into "no key"; keep them apart.
        let read: Result<String?, Error> = await Blocking.run { Result { try reader(context) } }
        guard case .success(let found) = read else { return .unreadable }
        return normalizedManagementKey(found).map { .key($0) } ?? .none
    }

    // MARK: - Collect

    static func collectAccount(_ key: String, _ context: CollectorContext) async -> Provider {
        // A detected key belongs in the bar, so a rejected one shows its error.
        var provider = Provider(id: .openrouter, available: true, tier: accountTier, source: accountSource)
        let http = context.httpClient

        let keys: [[String: Any]]
        switch await listKeys(key, http: http) {
        case .failure(let f):
            return failed(provider, f, endpoint: .keys, key: key)
        case .success(let list):
            keys = list
        }
        var credits: (total: Double, used: Double, remaining: Double)?
        switch await fetch(creditsURL, key: key, http: http) {
        case .success(let doc):
            credits = pickCredits(doc)
        case .failure(let f):
            // Some accounts can't read credits (404); everything else is a real failure.
            if case .status(404, _) = f { credits = nil }
            else { return failed(provider, f, endpoint: .credits, key: key) }
        }

        let enabled = activeKeys(keys, now: context.now)
        var money = Money(label: Money.accountWideLabel, limit: nil,
                          spend: enabled.reduce(0) { $0 + max(0, Sanitize.number($1["usage_monthly"]) ?? 0) },
                          credits: nil, totalCredits: nil, resetInterval: "monthly",
                          resetsAt: nextMonthlyReset(context.now))
        var limits: [Limit] = []
        if let credits {
            money.credits = credits.remaining
            money.totalCredits = credits.total
            limits.append(creditsLimit(credits))
        }
        limits += keyLimits(enabled, now: context.now)

        provider.money = money
        provider.limits = limits
        provider.status = enabled.count == 1 ? "1 key" : "\(enabled.count) keys"
        provider.readAt = context.nowMs
        return provider
    }

    /// Settings › Save: one `GET /api/v1/keys` (all pages). Never echoes the key.
    public static func verifyManagementKey(_ raw: String, http: HTTPClient, now: Date = Date()) async -> (ok: Bool, message: String) {
        if let problem = managementKeyProblem(raw) { return (false, problem) }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await listKeys(key, http: http) {
        case .success(let list):
            let n = activeKeys(list, now: now).count
            return (true, "Verified \u{00B7} " + (n == 1 ? "1 key" : "\(n) keys"))
        case .failure(let f):
            return (false, describe(f, endpoint: .keys, key: key).error)
        }
    }

    // MARK: - HTTP

    enum ManagementFailure: Error, Equatable {
        case status(Int, String)   // HTTP status, display-safe API message
        case transport(String)
        case invalid
    }

    enum Endpoint { case keys, credits }

    static func fetch(_ url: String, key: String, http: HTTPClient) async -> Result<[String: Any], ManagementFailure> {
        let headers = [
            "Authorization": "Bearer " + key,
            "Accept": "application/json",
            "User-Agent": "the-agentic-apple/1.0",
        ]
        let response: HTTPResponse
        do {
            response = try await http.get(url, headers)
        } catch let e as HTTPError {
            return .failure(.transport(scrub(e.description, key: key)))
        } catch {
            return .failure(.transport("could not reach OpenRouter"))
        }
        let doc = response.json
        if (200..<300).contains(response.status) {
            guard let doc else { return .failure(.invalid) }
            return .success(doc)
        }
        var message = ""
        if let err = doc?["error"] as? [String: Any], let m = err["message"] as? String {
            message = scrub(String(m.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)), key: key)
        }
        return .failure(.status(response.status, message))
    }

    /// Every page of `/api/v1/keys` (100 per page, at most `maxKeyPages`).
    static func listKeys(_ key: String, http: HTTPClient) async -> Result<[[String: Any]], ManagementFailure> {
        var all: [[String: Any]] = []
        var offset = 0
        for _ in 0..<maxKeyPages {
            switch await fetch(keysURL + "?offset=\(offset)", key: key, http: http) {
            case .failure(let f):
                return .failure(f)
            case .success(let doc):
                guard let page = doc["data"] as? [Any] else { return .failure(.invalid) }
                let items = page.compactMap { $0 as? [String: Any] }
                all += items
                if page.count < keysPageSize { return .success(all) }
                offset += page.count
            }
        }
        return .success(all)
    }

    /// Plain status, hint and error for a failure. The error stands on its own
    /// (the panel hides the hint while last good numbers are shown).
    static func describe(_ f: ManagementFailure, endpoint: Endpoint, key: String) -> (status: String, hint: String, error: String) {
        switch f {
        case .status(401, _):
            return (expiredStatus, expiredHint,
                    "OpenRouter rejected the management key (HTTP 401: expired or invalid). Replace or remove it in Settings \u{203A} Advanced.")
        case .status(403, _):
            return ("Management key not allowed", "",
                    "This management key isn't allowed to read \(endpoint == .keys ? "the account's keys" : "account credits") (HTTP 403).")
        case .status(404, _):
            return ("Management key can't list keys", "",
                    endpoint == .keys
                        ? "This management key can't list keys (personal accounts may need an organization)."
                        : "This management key can't read account credits.")
        case .status(let code, let message):
            return ("", "", message.isEmpty ? "HTTP \(code)" : "\(message) (HTTP \(code))")
        case .transport(let message):
            return ("", "", message)
        case .invalid:
            return ("", "", "invalid JSON from OpenRouter")
        }
    }

    static func failed(_ base: Provider, _ f: ManagementFailure, endpoint: Endpoint, key: String) -> Provider {
        var p = base
        let d = describe(f, endpoint: endpoint, key: key)
        if !d.status.isEmpty { p.status = d.status }
        p.hint = d.hint
        p.error = d.error + " " + noFallbackNote
        p.money = nil
        p.limits = []
        return p
    }

    // MARK: - Mapping

    /// Enabled keys whose `expires_at` (when given) is still ahead.
    static func activeKeys(_ keys: [[String: Any]], now: Date) -> [[String: Any]] {
        let nowMs = now.timeIntervalSince1970 * 1000
        return keys.filter { k in
            if (k["disabled"] as? Bool) == true { return false }
            let expires = Sanitize.dateMs(k["expires_at"])
            return expires <= 0 || expires > nowMs
        }
    }

    static func creditsLimit(_ c: (total: Double, used: Double, remaining: Double)) -> Limit {
        let percent = c.total > 0 ? c.used / c.total * 100 : 0
        return Limit(key: "credits", label: "Credits", short: "cr", percent: percent,
                     resetsAt: 0, limited: c.total > 0 && c.remaining <= 0)
    }

    /// One row per key with a positive limit, highest percent first, at most `maxKeyRows`.
    static func keyLimits(_ keys: [[String: Any]], now: Date) -> [Limit] {
        var rows: [Limit] = []
        for (index, k) in keys.enumerated() {
            guard let limit = Sanitize.number(k["limit"]), limit > 0 else { continue }
            let reset = (k["limit_reset"] as? String).map { $0.lowercased() }
            let remaining = Sanitize.number(k["limit_remaining"])
            let used: Double
            if let remaining {
                used = limit - remaining
            } else {
                let field: String
                switch reset {
                case "daily"?: field = "usage_daily"
                case "weekly"?: field = "usage_weekly"
                case "monthly"?: field = "usage_monthly"
                default: field = "usage"
                }
                used = Sanitize.number(k[field]) ?? 0
            }
            rows.append(Limit(key: rowKey(k["hash"], index: index), label: keyName(k), short: "key",
                              percent: used / limit * 100, resetsAt: nextReset(reset, now: now),
                              limited: (remaining ?? 1) <= 0))
        }
        // Stable: equal percents keep the API's order.
        let sorted = rows.enumerated().sorted { a, b in
            a.element.percent != b.element.percent ? a.element.percent > b.element.percent : a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(maxKeyRows))
    }

    static func rowKey(_ hash: Any?, index: Int) -> String {
        let h = ((hash as? String) ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return h.isEmpty ? "key-\(index + 1)" : "key-" + String(h.prefix(8)).lowercased()
    }

    /// The key's own name; else "Key …" and the label's last four letters or
    /// digits. Never the full label.
    static func keyName(_ k: [String: Any]) -> String {
        let name = Sanitize.plain(k["name"], max: 60).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        let raw = ((k["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = ""
        for ch in raw.reversed() {
            guard ch.isASCII, ch.isLetter || ch.isNumber else { break }
            tail.insert(ch, at: tail.startIndex)
        }
        return tail.count >= 4 ? "Key \u{2026}" + String(tail.suffix(4)) : "Key"
    }

    // MARK: - Reset dates (UTC)

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// `daily` / `weekly` / `monthly` → the next boundary in epoch ms; anything else → 0.
    public static func nextReset(_ interval: String?, now: Date) -> Double {
        switch interval?.lowercased() {
        case "daily"?: return nextDailyReset(now)
        case "weekly"?: return nextWeeklyReset(now)
        case "monthly"?: return nextMonthlyReset(now)
        default: return 0
        }
    }

    /// The next 00:00 UTC strictly after `now`.
    public static func nextDailyReset(_ now: Date) -> Double {
        let cal = utc
        let day = cal.startOfDay(for: now)
        return ms(cal.date(byAdding: .day, value: 1, to: day) ?? day)
    }

    /// The next Monday 00:00 UTC strictly after `now`.
    public static func nextWeeklyReset(_ now: Date) -> Double {
        let cal = utc
        let day = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: day)   // 1 = Sunday, 2 = Monday
        var ahead = (2 - weekday + 7) % 7
        if ahead == 0 { ahead = 7 }
        return ms(cal.date(byAdding: .day, value: ahead, to: day) ?? day)
    }

    /// The next 1st of a month, 00:00 UTC, strictly after `now`.
    public static func nextMonthlyReset(_ now: Date) -> Double {
        let cal = utc
        let parts = cal.dateComponents([.year, .month], from: now)
        guard let first = cal.date(from: parts),
              let next = cal.date(byAdding: .month, value: 1, to: first) else { return 0 }
        return ms(next)
    }

    private static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }
}
