import Foundation

/// Codex collector. (Stub — implemented by the Codex workstream.)
public struct CodexCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .codex }
    public func collect(_ context: CollectorContext) async -> Provider {
        Provider(id: .codex, source: "stub")
    }
}
