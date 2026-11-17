import Foundation
import AgenticCore

/// `AGENTIC_APPLE_FIXTURE=1` runs the menu bar app on the invented preview data
/// — for demos and for exercising the UI without touching any real account.
/// Times are shifted so reset countdowns are relative to the real clock, and
/// the cache lives in a temporary directory so real launches never see it.
enum FixtureCollectors {
    static var enabled: Bool { ProcessInfo.processInfo.environment["AGENTIC_APPLE_FIXTURE"] == "1" }

    static var cacheURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-apple-fixture", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    static func collector() -> Collector {
        Collector(collectors: ProviderID.defaultOrder.map { FixtureProviderCollector(id: $0) })
    }
}

private struct FixtureProviderCollector: ProviderCollector {
    let id: ProviderID

    func collect(_ context: CollectorContext) async -> Provider {
        let shift = context.nowMs - PreviewFixture.now
        guard var p = PreviewFixture.providers.first(where: { $0.id == id }) else { return Provider(id: id) }
        p.limits = p.limits.map { l in
            var l = l
            if l.resetsAt > 0 { l.resetsAt += shift }
            return l
        }
        if var m = p.money, m.resetsAt > 0 { m.resetsAt += shift; p.money = m }
        p.readAt = context.nowMs
        return p
    }
}
