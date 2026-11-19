import Foundation

/// OpenRouter has no subscription, so the bar compares this cycle's spend with
/// the previous completed cycle. The history keeps exactly one current and one
/// previous cycle; the previous one is kept only when it was observed within
/// six hours of its end (a missed cycle would be a misleading baseline).
///
/// Public API:
/// - `struct Cycle: Codable, Equatable { key: String; end: Double; spend: Double; lastObservedAt: Double }`
///   (`end`/`lastObservedAt` are epoch ms)
/// - `struct CycleHistory: Codable, Equatable { current: Cycle?; previous: Cycle?; older: Cycle? }`
///   (`older` is the cycle before `previous`, kept on the same rule; a cache
///   without it reads as nil)
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
    public var current: Cycle?
    public var previous: Cycle?
    /// The completed cycle before `previous` (OpenRouter account-wide two-month average).
    public var older: Cycle?

    public init(current: Cycle? = nil, previous: Cycle? = nil, older: Cycle? = nil) {
        self.current = current
        self.previous = previous
        self.older = older
    }

    public static let empty = CycleHistory()

    public func normalized() -> CycleHistory {
        guard let current = current?.normalized() else { return .empty }
        var previous = self.previous?.normalized()
        if let p = previous, p.end > current.end { previous = nil }
        var older = previous == nil ? nil : self.older?.normalized()
        if let o = older, let p = previous, o.end >= p.end { older = nil }
        return CycleHistory(current: current, previous: previous, older: older)
    }

    public func completedCycles() -> [Cycle] {
        let h = normalized()
        return [h.previous, h.older].compactMap { $0 }
    }

    public func advanced(with money: Money?, now: Double) -> CycleHistory {
        let h = normalized()
        guard let money, money.resetsAt.isFinite, money.resetsAt > 0 else { return h }
        let spend = money.spend.isFinite ? max(0, money.spend) : 0
        // Round once so a fractional ISO timestamp can't split one cycle in two.
        let end = money.resetsAt.rounded()
        let next = Cycle(key: "cycle:" + Format.integerText(end), end: end,
                         spend: spend, lastObservedAt: now)
        guard let current = h.current else { return CycleHistory(current: next, previous: nil) }
        if current.end == next.end {
            return CycleHistory(current: Cycle(key: next.key, end: next.end,
                                               spend: max(current.spend, next.spend), lastObservedAt: now),
                                previous: h.previous, older: h.older)
        }
        if next.end > current.end {
            let observedNearEnd = current.lastObservedAt >= current.end - 6 * 3_600_000
            // The chain moves down one; a missed end breaks it (no misleading baseline).
            return observedNearEnd
                ? CycleHistory(current: next, previous: current, older: h.previous)
                : CycleHistory(current: next, previous: nil, older: nil)
        }
        return h
    }
}
