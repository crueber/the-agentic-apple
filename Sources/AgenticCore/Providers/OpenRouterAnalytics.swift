import Foundation

/// OpenRouter account-wide: the average monthly spend of the previous N
/// calendar months (UTC; N = `openrouterAverageMonths`, 1–12, 0 = no meter and
/// no analytics), the baseline for the "All keys · this month" meter.
///
/// Endpoints (management key, `Authorization` header only):
/// - `GET  /api/v1/analytics/meta` — pick the cost metric: `display_format`
///   "currency", not `is_rate`, name/label about cost, usage or spend
///   (`pickCostMetric`). Remembered in memory for the run.
/// - `POST /api/v1/analytics/query` with
///   `{"metrics":["<metric>"],"granularity":"month","time_range":{"start":"<1st, two months ago>","end":"<1st of this month>"}}`
///   (`queryBody`). Rows are parsed defensively (`parseTotal`): anything
///   unexpected means "no baseline", never an error shown to the user.
///
/// Asked at most once per (month, N) per run (`AnalyticsMemo`), and not at all
/// when the cached provider already has this month's baseline for the same N
/// (`CollectorContext.openrouterBaseline`). Without one the Logic layer falls
/// back to the observed cycle history.
public final class AnalyticsMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var metric: String?
    private var attempts: [String: MonthlyBaseline?] = [:]

    public init() {}
    public static let shared = AnalyticsMemo()

    var costMetric: String? {
        get { lock.lock(); defer { lock.unlock() }; return metric }
        set { lock.lock(); metric = newValue; lock.unlock() }
    }

    /// `.some(result)` when this month was already tried in this run.
    func attempt(for month: String) -> MonthlyBaseline?? {
        lock.lock(); defer { lock.unlock() }
        return attempts[month]
    }

    func record(_ result: MonthlyBaseline?, for month: String) {
        lock.lock(); attempts[month] = .some(result); lock.unlock()
    }
}

extension OpenRouterCollector {
    public static let analyticsMetaURL = "https://openrouter.ai/api/v1/analytics/meta"
    public static let analyticsQueryURL = "https://openrouter.ai/api/v1/analytics/query"

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "2026-11" for a date (UTC).
    public static func monthKey(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public static let maxAverageMonths = 12
    public static let defaultAverageMonths = 2

    /// The 1st of `date`'s month and of the month `months` before it, 00:00 UTC.
    public static func baselineRange(_ date: Date, months: Int = 2) -> (start: Date, end: Date)? {
        let cal = utc
        guard (1...maxAverageMonths).contains(months),
              let end = cal.date(from: cal.dateComponents([.year, .month], from: date)),
              let start = cal.date(byAdding: .month, value: -months, to: end) else { return nil }
        return (start, end)
    }

    /// "Oct" for one month, "Sep–Oct" or "Aug–Oct" for a range starting at `start`.
    public static func rangeLabel(_ start: Date, months: Int = 2) -> String {
        let cal = utc
        let first = cal.component(.month, from: start)
        let lastDate = cal.date(byAdding: .month, value: max(0, months - 1), to: start) ?? start
        let last = cal.component(.month, from: lastDate)
        let a = monthNames[(first + 11) % 12], b = monthNames[(last + 11) % 12]
        return months <= 1 ? a : a + "\u{2013}" + b
    }

    static func isoSeconds(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Metric names are put into the JSON body verbatim, so only plain ones.
    static func isPlainMetricName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
        }
    }

    /// The account's cost metric from `/analytics/meta`, or nil.
    public static func pickCostMetric(_ doc: [String: Any]) -> String? {
        let src = (doc["data"] as? [String: Any]) ?? doc
        guard let metrics = src["metrics"] as? [Any] else { return nil }
        var best: (score: Int, name: String)?
        for case let m as [String: Any] in metrics {
            guard let name = m["name"] as? String, isPlainMetricName(name),
                  ((m["display_format"] as? String) ?? "").lowercased() == "currency",
                  (m["is_rate"] as? Bool) != true else { continue }
            let n = name.lowercased()
            let text = n + " " + ((m["display_label"] as? String) ?? "").lowercased()
            if text.contains("byok") { continue }   // bring-your-own-key spend is not OpenRouter's bill
            let score: Int
            if ["cost", "total_cost", "usage", "total_usage", "spend", "total_spend"].contains(n) { score = 3 }
            else if text.contains("cost") { score = 2 }
            else if text.contains("usage") || text.contains("spend") { score = 1 }
            else { continue }
            if best == nil || score > best!.score { best = (score, name) }
        }
        return best?.name
    }

    /// The exact request body for the `months` full months before `now`'s month.
    public static func queryBody(metric: String, now: Date, months: Int = 2) -> String? {
        guard isPlainMetricName(metric), let range = baselineRange(now, months: months) else { return nil }
        return #"{"metrics":[""# + metric + #""],"granularity":"month","time_range":{"start":""#
            + isoSeconds(range.start) + #"","end":""# + isoSeconds(range.end) + #""}}"#
    }

    /// The `months` months' total spend, or nil when the answer is not clearly that.
    /// - `data.data` rows, at most `months`; each must carry the metric as a number ≥ 0.
    /// - A row's time bucket (any string field that reads as a date) must fall in
    ///   the range, one row per month.
    /// - Fewer than `months` rows count the missing months as 0 only when the answer
    ///   says it is complete (`metadata.row_count` equals the rows, `truncated`
    ///   false) and every row has a bucket.
    /// - `truncated` true → nil.
    public static func parseTotal(_ doc: [String: Any], metric: String, start: Date, end: Date, months: Int = 2) -> Double? {
        guard let data = doc["data"] as? [String: Any], let rows = data["data"] as? [Any], rows.count <= months else { return nil }
        let meta = data["metadata"] as? [String: Any]
        if (meta?["truncated"] as? Bool) == true { return nil }
        let startMs = start.timeIntervalSince1970 * 1000, endMs = end.timeIntervalSince1970 * 1000
        var total = 0.0
        var seenMonths = Set<String>()
        var allBucketed = true
        for row in rows {
            guard let row = row as? [String: Any], let value = Sanitize.number(row[metric]), value >= 0 else { return nil }
            total += value
            var bucket: Double?
            for (field, raw) in row where field != metric {
                if let s = raw as? String, let ms = bucketDateMs(s) { bucket = ms; break }
            }
            if let bucket {
                guard bucket >= startMs, bucket < endMs else { return nil }
                guard seenMonths.insert(monthKey(Date(timeIntervalSince1970: bucket / 1000))).inserted else { return nil }
            } else {
                allBucketed = false
            }
        }
        if rows.count == months { return total }
        let complete = (meta?["truncated"] as? Bool) == false
            && Sanitize.number(meta?["row_count"]).map { Int($0) == rows.count } == true
        return complete && allBucketed ? total : nil
    }

    /// ISO date-time, "YYYY-MM-DD" or "YYYY-MM" (UTC) → epoch ms.
    static func bucketDateMs(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let iso = Sanitize.isoDateMs(t)
        if iso > 0 { return iso }
        let parts = t.split(separator: "-")
        guard (2...3).contains(parts.count), parts[0].count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        let d = parts.count == 3 ? Int(parts[2]) ?? 0 : 1
        guard (1...31).contains(d),
              let date = utc.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    /// The baseline for `context.now`'s month: the cached one, this run's earlier
    /// attempt, or one meta + query round trip. nil when unavailable.
    /// Keyed by (month, N): changing N asks again, once.
    static func accountBaseline(_ key: String, _ context: CollectorContext, memo: AnalyticsMemo) async -> MonthlyBaseline? {
        let months = context.openrouterAverageMonths
        guard (1...maxAverageMonths).contains(months) else { return nil }   // 0 = usage meter off: no analytics
        let month = monthKey(context.now)
        if let cached = context.openrouterBaseline, cached.month == month, cached.months == months, cached.average > 0 {
            return cached
        }
        let attemptKey = month + "#" + String(months)
        if let earlier = memo.attempt(for: attemptKey) { return earlier }
        let result = await queryBaseline(key, context, memo: memo, month: month, months: months)
        memo.record(result, for: attemptKey)
        return result
    }

    static func queryBaseline(_ key: String, _ context: CollectorContext, memo: AnalyticsMemo,
                              month: String, months: Int) async -> MonthlyBaseline? {
        let http = context.httpClient
        guard http.post != nil, let range = baselineRange(context.now, months: months) else { return nil }
        var metric = memo.costMetric
        if metric == nil {
            guard case .success(let doc) = await fetch(analyticsMetaURL, key: key, http: http),
                  let picked = pickCostMetric(doc) else { return nil }
            memo.costMetric = picked
            metric = picked
        }
        guard let metric, let body = queryBody(metric: metric, now: context.now, months: months),
              case .success(let doc) = await fetch(analyticsQueryURL, key: key, http: http, body: Data(body.utf8)),
              let total = parseTotal(doc, metric: metric, start: range.start, end: range.end, months: months) else { return nil }
        let average = total / Double(months)
        guard average.isFinite, average > 0 else { return nil }
        return MonthlyBaseline(month: month, average: average, months: months, label: rangeLabel(range.start, months: months))
    }
}
