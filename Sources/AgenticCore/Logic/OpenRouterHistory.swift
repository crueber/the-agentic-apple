import Foundation

/// OpenRouter has no subscription, so the bar compares this cycle's spend with
/// the previous completed cycle (account-wide: the average of the last N). The
/// history keeps one current and up to twelve completed cycles; a completed one
/// is kept only when it was observed within six hours of its end (a missed
/// cycle would be a misleading baseline, so it breaks the chain).
///
/// Public API:
/// - `struct Cycle: Codable, Equatable { key: String; end: Double; spend: Double; lastObservedAt: Double }`
///   (`end`/`lastObservedAt` are epoch ms)
/// - `struct CycleHistory: Codable, Equatable { current: Cycle?; completed: [Cycle] }`
///   (up to 12 completed cycles, most recent first; `previous`/`older` are the
///   first two; a 1.0 cache's `previous`/`older` keys are migrated into `completed`)
///   - `static let empty`
///   - `func normalized() -> CycleHistory`        drops invalid cycles; no current ⇒ empty;
///                                                 a previous ending after current is dropped,
///                                                 an older not ending before previous too
///   - `func completedCycles() -> [Cycle]`         previous, then older (what exists)
///   - `func advanced(with money: Money?, now: Double) -> CycleHistory`
///                                                 feed it OpenRouter's money after every fetch
public struct Cycle: Codable, Equatable, Sendable {
    public var key: String
    public var end: Double
    public var spend: Double
    public var lastObservedAt: Double

    public init(key: String, end: Double, spend: Double, lastObservedAt: Double) {
        self.key = key
        self.end = end
        self.spend = spend
        self.lastObservedAt = lastObservedAt
    }

    /// nil when the cycle has no usable end.
    func normalized() -> Cycle? {
        guard end.isFinite, end > 0 else { return nil }
        let k = Sanitize.plain(key, max: 60)
        return Cycle(key: k.isEmpty ? Format.integerText(end.rounded()) : k,
                     end: end.rounded(),
                     spend: spend.isFinite ? max(0, spend) : 0,
                     lastObservedAt: lastObservedAt.isFinite && lastObservedAt > 0 ? lastObservedAt : 0)
    }
}

public struct CycleHistory: Codable, Equatable, Sendable {
    public static let maxCompleted = 12

    public var current: Cycle?
    /// Completed cycles, most recent first, each ending before the one before it
    /// in the list; at most `maxCompleted`. Kept on the six-hour rule: a cycle
    /// whose end was not observed breaks the chain.
    public var completed: [Cycle]

    /// The last completed cycle (the per-key view's baseline).
    public var previous: Cycle? { completed.first }
    /// The one before it.
    public var older: Cycle? { completed.count > 1 ? completed[1] : nil }

    public init(current: Cycle? = nil, previous: Cycle? = nil, older: Cycle? = nil) {
        self.current = current
        self.completed = [previous, previous == nil ? nil : older].compactMap { $0 }
    }

    public init(current: Cycle?, completed: [Cycle]) {
        self.current = current
        self.completed = Array(completed.prefix(Self.maxCompleted))
    }

    public static let empty = CycleHistory()

    // 1.0 caches have `previous` (and early 1.1 builds `older`): migrated into `completed`.
    enum CodingKeys: String, CodingKey { case current, completed, previous, older }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = try c.decodeIfPresent(Cycle.self, forKey: .current)
        if let list = try c.decodeIfPresent([Cycle].self, forKey: .completed) {
            completed = Array(list.prefix(Self.maxCompleted))
        } else {
            let previous = try c.decodeIfPresent(Cycle.self, forKey: .previous)
            let older = try c.decodeIfPresent(Cycle.self, forKey: .older)
            completed = [previous, previous == nil ? nil : older].compactMap { $0 }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(current, forKey: .current)
        try c.encode(completed, forKey: .completed)
        // Still readable by 1.0.x if someone downgrades.
        try c.encodeIfPresent(previous, forKey: .previous)
    }

    /// Drops invalid cycles; no current ⇒ empty; the completed chain is cut at
    /// the first cycle that does not end before the one after it (or current).
    public func normalized() -> CycleHistory {
        guard let current = current?.normalized() else { return .empty }
        var chain: [Cycle] = []
        var limit = current.end
        for raw in completed.prefix(Self.maxCompleted) {
            guard let cycle = raw.normalized() else { break }
            let ok = chain.isEmpty ? cycle.end <= limit : cycle.end < limit
            guard ok else { break }
            chain.append(cycle)
            limit = cycle.end
        }
        return CycleHistory(current: current, completed: chain)
    }

    public func completedCycles() -> [Cycle] { normalized().completed }

    public func advanced(with money: Money?, now: Double) -> CycleHistory {
        let h = normalized()
        guard let money, money.resetsAt.isFinite, money.resetsAt > 0 else { return h }
        let spend = money.spend.isFinite ? max(0, money.spend) : 0
        // Round once so a fractional ISO timestamp can't split one cycle in two.
        let end = money.resetsAt.rounded()
        let next = Cycle(key: "cycle:" + Format.integerText(end), end: end,
                         spend: spend, lastObservedAt: now)
        guard let current = h.current else { return CycleHistory(current: next, completed: []) }
        if current.end == next.end {
            return CycleHistory(current: Cycle(key: next.key, end: next.end,
                                               spend: max(current.spend, next.spend), lastObservedAt: now),
                                completed: h.completed)
        }
        if next.end > current.end {
            let observedNearEnd = current.lastObservedAt >= current.end - 6 * 3_600_000
            // The chain moves down one; a missed end breaks it (no misleading baseline).
            return CycleHistory(current: next, completed: observedNearEnd ? [current] + h.completed : [])
        }
        return h
    }
}
