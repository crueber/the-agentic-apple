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
public enum ProviderMerge {
    public static func merge(previous: [Provider], fresh: [Provider]) -> [Provider] {
        fresh.map { next in
            guard !next.error.isEmpty,
                  next.limits.isEmpty, next.money == nil, next.budgets.isEmpty,
                  let old = previous.first(where: { $0.id == next.id }), old.available else { return next }
            var merged = old
            if !next.tier.isEmpty { merged.tier = next.tier }
            if !next.status.isEmpty { merged.status = next.status }
            merged.hint = next.hint
            if next.activity != .empty { merged.activity = next.activity }
            merged.error = next.error
            return merged
        }
    }
}
