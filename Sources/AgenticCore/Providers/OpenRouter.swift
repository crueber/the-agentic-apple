import Foundation

/// OpenRouter collector. (Stub — implemented by the OpenRouter workstream.)
public struct OpenRouterCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .openrouter }
    public func collect(_ context: CollectorContext) async -> Provider {
        Provider(id: .openrouter, source: "stub")
    }
}
