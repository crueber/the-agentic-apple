import Foundation

/// The last good result on disk, painted immediately on launch (README "How it
/// fetches"). Same document shape as the reference plugin:
/// `{ version: 1, fetchedAt, attemptedAt, failures, error, data: { providers }, history }`.
/// Providers carry no key material (OpenRouter keys are only ever a masked label).
///
/// Public API:
/// - `struct UsageCache: Equatable { providers: [Provider]; history: CycleHistory;
///    fetchedAt: Double; attemptedAt: Double; failures: Int; error: String }`
///   - `init(providers:history:fetchedAt:attemptedAt:failures:error:)` (all defaulted)
///   - `static let version = 1`
///   - `func serialize() -> String`                      JSON + "\n"
///   - `static func parse(_ raw: String, now: Double) -> UsageCache?`
///   - `static func parse(data: Data, now: Double) -> UsageCache?`
///         nil for garbage or another version; unknown/broken providers are dropped
///         one by one; timestamps > 5 min in the future become 0; everything re-sanitised
///   - `func write(to url: URL) throws`    parent dir created/forced to 0700, atomic write, file 0600
///   - `static func read(from url: URL, now: Double) -> UsageCache?`
///   - `static func slim(_ provider: Provider) -> Provider`   sanitised copy (≤ 16 limits, 12 budgets,
///         bounded display-safe strings, finite numbers) — what the cache stores
///   - `static func defaultURL(home:) -> URL`   ~/Library/Caches/com.crueber.agentic-apple/usage.json
public struct UsageCache: Equatable, Sendable {
    public static let version = 1
    static let maxBytes = 2 * 1024 * 1024
    static let futureSlackMs: Double = 300_000

    public var providers: [Provider]
    public var history: CycleHistory
    public var fetchedAt: Double
    public var attemptedAt: Double
    public var failures: Int
    public var error: String

    public init(providers: [Provider] = [], history: CycleHistory = .empty, fetchedAt: Double = 0,
                attemptedAt: Double = 0, failures: Int = 0, error: String = "") {
        self.providers = providers
        self.history = history
        self.fetchedAt = fetchedAt
        self.attemptedAt = attemptedAt
        self.failures = failures
        self.error = error
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches/com.crueber.agentic-apple/usage.json")
    }

    // MARK: sanitising

    static func finite(_ x: Double, _ fallback: Double = 0) -> Double { x.isFinite ? x : fallback }

    public static func slim(_ provider: Provider) -> Provider {
        var p = provider
        p.name = provider.id.displayName
        p.tier = Sanitize.plain(provider.tier, max: 80)
        p.status = Sanitize.plain(provider.status, max: 160)
        p.hint = Sanitize.plain(provider.hint, max: 300)
        p.error = Sanitize.plain(provider.error, max: 300)
        p.source = Sanitize.plain(provider.source, max: 40)
        p.limits = provider.limits.prefix(16).compactMap { l in
            let key = Sanitize.plain(l.key, max: 80)
            if key.isEmpty { return nil }
            let label = Sanitize.plain(l.label, max: 100)
            let short = Sanitize.plain(l.short, max: 16)
            return Limit(key: key, label: label.isEmpty ? key : label, short: short.isEmpty ? key : short,
                         percent: l.percent, resetsAt: max(0, finite(l.resetsAt)),
                         limited: l.limited, stale: l.stale, amount: l.amount)
        }
        p.activity = Activity(period: provider.activity.period == "week" ? "week" : "today",
                              prompts: provider.activity.prompts, tokens: provider.activity.tokens)
        if let m = provider.money {
            let limit = m.limit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            p.money = Money(label: Sanitize.plain(m.label, max: 80), limit: limit,
                            spend: max(0, finite(m.spend)),
                            credits: m.credits.flatMap { $0.isFinite ? $0 : nil },
                            totalCredits: m.totalCredits.flatMap { $0.isFinite ? $0 : nil },
                            resetInterval: String(m.resetInterval.prefix(24)),
                            resetsAt: max(0, finite(m.resetsAt)),
                            baseline: m.baseline.flatMap { b in
                                b.average.isFinite && b.average > 0
                                    ? MonthlyBaseline(month: Sanitize.plain(b.month, max: 7), average: b.average,
                                                      months: min(2, max(1, b.months)), label: Sanitize.plain(b.label, max: 16))
                                    : nil
                            })
        }
        p.budgets = provider.budgets.prefix(12).map { b in
            Budget(label: Sanitize.plain(b.label, max: 80), spend: max(0, finite(b.spend)),
                   limit: max(0, finite(b.limit)), percent: b.percent)
        }
        p.readAt = max(0, finite(provider.readAt))
        return p
    }

    // MARK: document

    private struct Document: Codable {
        var version: Int
        var fetchedAt: Double
        var attemptedAt: Double
        var failures: Int
        var error: String
        var data: Payload
        var history: CycleHistory
    }

    private struct Payload: Codable {
        var providers: [Provider]
    }

    /// Decodes only what it can: each field and each provider independently.
    private struct LenientDocument: Decodable {
        var version: Int?
        var fetchedAt: Double
        var attemptedAt: Double
        var failures: Int
        var error: String
        var providers: [Provider]
        var history: CycleHistory

        enum Keys: String, CodingKey { case version, fetchedAt, attemptedAt, failures, error, data, history }
        enum DataKeys: String, CodingKey { case providers }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            version = try? c.decode(Int.self, forKey: .version)
            fetchedAt = (try? c.decode(Double.self, forKey: .fetchedAt)) ?? 0
            attemptedAt = (try? c.decode(Double.self, forKey: .attemptedAt)) ?? 0
            failures = (try? c.decode(Double.self, forKey: .failures)).map { $0.isFinite ? Int(Format.jsRound(Sanitize.clamp($0, 0, 1e6))) : 0 } ?? 0
            error = (try? c.decode(String.self, forKey: .error)) ?? ""
            history = (try? c.decode(CycleHistory.self, forKey: .history)) ?? .empty
            if let d = try? c.nestedContainer(keyedBy: DataKeys.self, forKey: .data),
               let list = try? d.decode([Lossy<Provider>].self, forKey: .providers) {
                providers = list.compactMap(\.value)
            } else {
                providers = []
            }
        }
    }

    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public func serialize() -> String {
        let doc = Document(
            version: Self.version,
            fetchedAt: Self.finite(fetchedAt), attemptedAt: Self.finite(attemptedAt),
            failures: max(0, failures), error: Sanitize.plain(error, max: 240),
            data: Payload(providers: providers.map(Self.slim)),
            history: history.normalized())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "0", negativeInfinity: "0", nan: "0")
        guard let data = try? encoder.encode(doc), let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }

    public static func parse(_ raw: String, now: Double) -> UsageCache? {
        parse(data: Data(raw.utf8), now: now)
    }

    public static func parse(data: Data, now: Double) -> UsageCache? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let doc = try? JSONDecoder().decode(LenientDocument.self, from: bytes),
              doc.version == version else { return nil }
        var fetchedAt = finite(doc.fetchedAt)
        var attemptedAt = finite(doc.attemptedAt)
        if fetchedAt > now + futureSlackMs { fetchedAt = 0 }
        if attemptedAt > now + futureSlackMs { attemptedAt = 0 }
        return UsageCache(providers: doc.providers.map(slim),
                          history: doc.history.normalized(),
                          fetchedAt: max(0, fetchedAt), attemptedAt: max(0, attemptedAt),
                          failures: max(0, doc.failures),
                          error: Sanitize.plain(doc.error, max: 240))
    }

    // MARK: file I/O

    public func write(to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try Data(serialize().utf8).write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL, now: Double) -> UsageCache? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data, now: now)
    }
}
