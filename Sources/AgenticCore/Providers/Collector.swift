import Foundation

/// Runs every provider concurrently and returns them in the default order.
///
/// - `Collector.all` — the six collectors with in-memory state (tests, previews).
/// - `Collector.live(cacheDir:)` — what the app and CLI use: Claude's activity scan
///   persists to `<cacheDir>/claude-activity.json` between refreshes.
public struct Collector: Sendable {
    public var collectors: [any ProviderCollector]

    public init(collectors: [any ProviderCollector] = Collector.all) {
        self.collectors = collectors
    }

    public static let all: [any ProviderCollector] = [
        OpenRouterCollector(), OpenCodeCollector(), GrokCollector(), CodexCollector(), ClaudeCollector(),
        AntigravityCollector(),
    ]

    /// The app's collector set. `cacheDir` defaults to the usage cache's directory
    /// (~/Library/Caches/com.crueber.agentic-apple).
    public static func live(cacheDir: URL = UsageCache.defaultURL().deletingLastPathComponent()) -> Collector {
        Collector(collectors: [
            OpenRouterCollector(), OpenCodeCollector(), GrokCollector(), CodexCollector(),
            ClaudeCollector(activityCache: cacheDir.appendingPathComponent("claude-activity.json")),
            AntigravityCollector(),
        ])
    }

    public func collect(_ context: CollectorContext) async -> [Provider] {
        await withTaskGroup(of: Provider.self) { group in
            for c in collectors { group.addTask { await c.collect(context) } }
            var out: [Provider] = []
            for await p in group { out.append(p) }
            return ProviderID.defaultOrder.compactMap { id in out.first { $0.id == id } }
        }
    }
}
