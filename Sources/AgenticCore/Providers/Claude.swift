import Foundation

/// Claude collector. (Stub — implemented by the Claude workstream.)
public struct ClaudeCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .claude }
    public func collect(_ context: CollectorContext) async -> Provider {
        Provider(id: .claude, source: "stub")
    }
}
