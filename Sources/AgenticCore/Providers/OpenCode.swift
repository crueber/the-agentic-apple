import Foundation

/// OpenCode collector, ported from the reference `collectOpencode`.
///
/// Limits come from the local OpenCode service:
/// `opencode api GET /api/experimental/usage/limits` (retried once with
/// `--standalone`). Today's activity is read from OpenCode's own SQLite store
/// (`~/.local/share/opencode/opencode.db`) with `/usr/bin/sqlite3 -readonly`;
/// only counts and token sums are selected, never message text.
public struct OpenCodeCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .opencode }

    public static let usagePath = "/api/experimental/usage/limits"
    public static let sqlitePath = "/usr/bin/sqlite3"

    struct Window {
        let key: String, label: String, short: String, field: String
    }

    static let windows: [Window] = [
        Window(key: "session", label: "5-hour session", short: "5h", field: "rolling"),
        Window(key: "weekly", label: "Weekly (7-day)", short: "7d", field: "weekly"),
        Window(key: "monthly", label: "Monthly", short: "1m", field: "monthly"),
    ]

    enum Answer {
        case data([String: Any])
        case signedOut
        case error(String)
    }

    public func collect(_ context: CollectorContext) async -> Provider {
        var provider = Provider(id: .opencode, source: "opencode-api")
        // sqlite3 and opencode are child processes; keep them off the cooperative pool.
        provider.activity = await Blocking.run { Self.activity(context) }

        guard let command = context.resolveCommand(context.opencodeCommand, default: "opencode") else {
            provider.error = "opencode not found"
            return provider
        }

        let data: [String: Any]
        switch await Blocking.run({ Self.fetch(command: command, context: context) }) {
        case .error(let message):
            provider.error = message
            return provider
        case .signedOut:
            provider.status = "Not signed in"
            return provider
        case .data(let d):
            data = d
        }

        let workspace = data["workspace"] as? [String: Any]
        // As the reference: tier is the workspace, status the plan ("demo · Go").
        provider.tier = workspace.map { Sanitize.plain($0["name"], max: 60) } ?? ""
        provider.status = "Go"
        provider.readAt = context.nowMs
        guard let go = data["go"] as? [String: Any] else {
            provider.status = "No Go plan"
            return provider
        }

        for window in Self.windows {
            guard let entry = go[window.field] as? [String: Any],
                  let percent = Sanitize.number(entry["percent"]) else { continue }
            provider.limits.append(Limit(key: window.key, label: window.label, short: window.short,
                                         percent: Sanitize.clamp(percent, 0, 100),
                                         resetsAt: Sanitize.dateMs(entry["resetsAt"]),
                                         limited: (entry["limited"] as? Bool) == true))
        }

        if let budgets = data["budgets"] as? [Any] {
            provider.budgets = budgets
                .compactMap { $0 as? [String: Any] }
                .filter { (Sanitize.number($0["limit"]) ?? 0) > 0 }
                .prefix(6)
                .map { entry in
                    let limit = Sanitize.number(entry["limit"]) ?? 0
                    let spent = Sanitize.number(entry["spent"]) ?? 0
                    let label = Sanitize.plain(entry["name"], max: 60).isEmpty
                        ? Sanitize.plain(entry["id"], max: 60)
                        : Sanitize.plain(entry["name"], max: 60)
                    return Budget(label: label, spend: spent, limit: limit,
                                  percent: limit > 0 ? Sanitize.clamp(spent / limit * 100, 0, 100) : 0)
                }
        }

        provider.available = !provider.limits.isEmpty
        return provider
    }

    // MARK: - Usage API

    static func fetch(command: String, context: CollectorContext) -> Answer {
        let env = context.childEnvironment
        var doc = Shell.runJSON(command, ["api", "GET", usagePath], environment: env)
        if doc == nil || doc?["data"] == nil {
            doc = Shell.runJSON(command, ["api", "--standalone", "GET", usagePath], environment: env)
        }
        guard let doc else { return .error("opencode did not answer") }
        if let data = doc["data"] {
            if data is NSNull { return .signedOut }
            if let d = data as? [String: Any] { return .data(d) }
            return .error("opencode returned no usage data")
        }
        return .data(doc)
    }

    // MARK: - Today's activity (local store)

    /// `$XDG_DATA_HOME/opencode/opencode.db` when present, else `~/.local/share/opencode/opencode.db`.
    static func databaseURL(_ context: CollectorContext) -> URL? {
        var candidates: [URL] = []
        if let xdg = context.environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: xdg).appendingPathComponent("opencode/opencode.db"))
        }
        candidates.append(context.home.appendingPathComponent(".local/share/opencode/opencode.db"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Local midnight of `context.now`, in epoch ms.
    static func startOfDayMs(_ context: CollectorContext) -> Int64 {
        Int64(Calendar.current.startOfDay(for: context.now).timeIntervalSince1970 * 1000)
    }

    /// Prompts = user messages created today; tokens = input + output +
    /// reasoning + cache read/write of assistant messages created today.
    /// OpenCode 2 stores messages in `session_message` (typed rows); OpenCode 1
    /// in `message` (`data.role`). Unknown schema → empty activity.
    static func activity(_ context: CollectorContext) -> Activity {
        guard FileManager.default.isExecutableFile(atPath: sqlitePath),
              let db = databaseURL(context) else { return .empty }

        let tables = sqlite(db, "select name from sqlite_master where type='table' and name in ('session_message','message');")
        let names = Set(tables.compactMap { $0["name"] as? String })
        let since = startOfDayMs(context)
        let tokenSum = """
            coalesce(json_extract(data,'$.tokens.input'),0)+coalesce(json_extract(data,'$.tokens.output'),0)\
            +coalesce(json_extract(data,'$.tokens.reasoning'),0)+coalesce(json_extract(data,'$.tokens.cache.read'),0)\
            +coalesce(json_extract(data,'$.tokens.cache.write'),0)
            """
        let sql: String
        if names.contains("session_message") {
            sql = """
                select (select count(*) from session_message where type='user' and time_created >= \(since)) as prompts,
                (select coalesce(sum(\(tokenSum)),0) from session_message where type='assistant' and time_created >= \(since)) as tokens;
                """
        } else if names.contains("message") {
            sql = """
                select (select count(*) from message where json_extract(data,'$.role')='user' and time_created >= \(since)) as prompts,
                (select coalesce(sum(\(tokenSum)),0) from message where json_extract(data,'$.role')='assistant' and time_created >= \(since)) as tokens;
                """
        } else {
            return .empty
        }
        guard let row = sqlite(db, sql).first else { return .empty }
        let prompts = Sanitize.number(row["prompts"]) ?? 0
        let tokens = Sanitize.number(row["tokens"]) ?? 0
        return Activity(period: "today", prompts: Int(min(prompts, 1e12)), tokens: Int(min(tokens, 1e15)))
    }

    /// Run a read-only query; rows as dictionaries (`sqlite3 -json`).
    static func sqlite(_ db: URL, _ sql: String) -> [[String: Any]] {
        let r = Shell.run(sqlitePath, ["-readonly", "-json", "-cmd", ".timeout 2000", db.path, sql], timeout: 8)
        guard r.ok, let rows = try? JSONSerialization.jsonObject(with: r.stdout) as? [Any] else { return [] }
        return rows.compactMap { $0 as? [String: Any] }
    }
}
