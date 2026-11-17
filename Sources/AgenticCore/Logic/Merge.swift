import Foundation

/// Merging a fresh collection with the previous one (README "How it fetches":
/// a failed provider keeps its last good numbers and gains an error, so one
/// endpoint being down never blanks the other agents).
///
/// Public API:
/// - `ProviderMerge.merge(previous: [Provider], fresh: [Provider]) -> [Provider]`
///   Result follows `fresh` (order and membership). A fresh entry with a non-empty
///   `error` and no limits, money or budgets, whose previous entry was available,
///   becomes the previous entry (limits, money, budgets, source, readAt, available)
///   with the fresh error and hint, and the fresh tier/status/activity where non-empty.
///   A fresh entry in a *paused* state (`pausedStatuses`: Claude's "Sign-in expired" /
///   "Limits paused", no error, no limits) whose previous entry had limits keeps those
///   limits marked `stale`, with the fresh status, hint and tier, and stays available.
/// - `ProviderMerge.pausedStatuses: Set<String>`
public enum ProviderMerge {
    /// Statuses that mean "the source can't be read right now, but the plan is still there".
    public static let pausedStatuses: Set<String> = ["Sign-in expired", "Limits paused"]

    public static func merge(previous: [Provider], fresh: [Provider]) -> [Provider] {
        fresh.map { next in
            guard next.limits.isEmpty, next.money == nil, next.budgets.isEmpty,
                  let old = previous.first(where: { $0.id == next.id }), old.available else { return next }
            if !next.error.isEmpty {
                var merged = old
                if !next.tier.isEmpty { merged.tier = next.tier }
                if !next.status.isEmpty { merged.status = next.status }
                merged.hint = next.hint
                if next.activity != .empty { merged.activity = next.activity }
                merged.error = next.error
                return merged
            }
            if pausedStatuses.contains(next.status), !old.limits.isEmpty {
                var merged = next
                merged.limits = old.limits.map { var l = $0; l.stale = true; return l }
                if merged.tier.isEmpty { merged.tier = old.tier }
                merged.readAt = old.readAt
                merged.available = true
                return merged
            }
            return next
        }
    }
}
