import Foundation

/// Grok collector. (Stub — implemented by the Grok workstream.)
public struct GrokCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .grok }
    public func collect(_ context: CollectorContext) async -> Provider {
        Provider(id: .grok, source: "stub")
    }
}
