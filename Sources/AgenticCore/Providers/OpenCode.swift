import Foundation

/// OpenCode collector. (Stub — implemented by the OpenCode workstream.)
public struct OpenCodeCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .opencode }
    public func collect(_ context: CollectorContext) async -> Provider {
        Provider(id: .opencode, source: "stub")
    }
}
