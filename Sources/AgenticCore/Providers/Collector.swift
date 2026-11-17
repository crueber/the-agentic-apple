import Foundation

/// Runs every provider concurrently and returns them in the default order.
public struct Collector: Sendable {
    public var collectors: [any ProviderCollector]

    public init(collectors: [any ProviderCollector] = Collector.all) {
        self.collectors = collectors
    }

    public static let all: [any ProviderCollector] = [
        OpenRouterCollector(), OpenCodeCollector(), GrokCollector(), CodexCollector(), ClaudeCollector(),
    ]

    public func collect(_ context: CollectorContext) async -> [Provider] {
        await withTaskGroup(of: Provider.self) { group in
            for c in collectors { group.addTask { await c.collect(context) } }
            var out: [Provider] = []
            for await p in group { out.append(p) }
            return ProviderID.defaultOrder.compactMap { id in out.first { $0.id == id } }
        }
    }
}
