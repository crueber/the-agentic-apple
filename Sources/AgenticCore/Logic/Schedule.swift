import Foundation

/// Refresh scheduling (README "How it fetches"). Automatic refresh every
/// `refreshIntervalSec` (default 5 min, 60–3600 s); manual refresh at most once
/// every 30 s; failed reads back off 1 → 2 → 4 → 8 → 10 min. The reference's
/// multi-monitor leader election is not needed on macOS and is not ported.
///
/// Public API (times in epoch ms):
/// - `Schedule.autoMinMs` (60 000), `forceMinMs` (30 000), `failureCapMs` (600 000),
///   `defaultRefreshMs` (300 000), `maxFailures` (20), `minDelayMs` (250)
/// - `Schedule.autoDelayMs(fetchedAt:attemptedAt:failures:refreshMs:now:) -> Double`
///       ms until the next automatic fetch (≥ 250)
/// - `Schedule.canFetch(lastAttemptMs:now:manual:) -> Bool`
///       false while within 30 s (manual) / 60 s (automatic) of the last attempt
/// - `Schedule.nextFailures(_ failures: Int) -> Int`  failure counter after one more failure (cap 20)
/// - `Schedule.clampInt(_ value: Double?, _ low: Int, _ high: Int, fallback: Int) -> Int`
///       settings sanitiser: interval (60…3600, 300), thresholds (0…100, 70 / 90)
public enum Schedule {
    public static let autoMinMs: Double = 60_000
    public static let forceMinMs: Double = 30_000
    public static let failureCapMs: Double = 600_000
    public static let defaultRefreshMs: Double = 300_000
    public static let maxFailures = 20
    public static let minDelayMs: Double = 250

    public static func autoDelayMs(fetchedAt: Double, attemptedAt: Double, failures: Int,
                                   refreshMs: Double, now: Double) -> Double {
        let refresh = refreshMs.isFinite && refreshMs != 0 ? refreshMs : defaultRefreshMs
        let interval = max(autoMinMs, refresh)
        let fails = max(0, failures)
        let fetched = fetchedAt.isFinite ? fetchedAt : 0
        let attempted = attemptedAt.isFinite ? attemptedAt : 0
        if fails > 0 {
            let backoff = min(failureCapMs, 60_000 * pow(2, Double(min(fails - 1, 4))))
            let base = attempted != 0 ? attempted : now
            return max(minDelayMs, min(backoff, base + backoff - now))
        }
        let last = max(fetched, attempted)
        if last <= 0 { return minDelayMs }
        return max(minDelayMs, last + interval - now)
    }

    public static func canFetch(lastAttemptMs: Double, now: Double, manual: Bool) -> Bool {
        let floor = manual ? forceMinMs : autoMinMs
        if lastAttemptMs.isFinite, lastAttemptMs > 0, now - lastAttemptMs < floor { return false }
        return true
    }

    public static func nextFailures(_ failures: Int) -> Int {
        min(maxFailures, max(0, failures) + 1)
    }

    public static func clampInt(_ value: Double?, _ low: Int, _ high: Int, fallback: Int) -> Int {
        guard let n = value, n.isFinite else { return fallback }
        return Int(Format.jsRound(Sanitize.clamp(n, Double(low), Double(high))))
    }
}
