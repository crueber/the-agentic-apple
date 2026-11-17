import Foundation
import AgenticCore

/// Command-line modes on the app's executable. They never start the UI.
///
///   --json                 collect once, print providers + windows as JSON
///   --text                 one line per agent shown in the bar ("no agents" when none)
///   --render-preview <dir> synthetic-data PNGs of the bar and panel (light + dark, @2x)
///   --unregister-login-item  remove the SMAppService login item (scripts/uninstall.sh)
///   --version, --help
///
/// `--fixture` (or AGENTIC_APPLE_FIXTURE=1) swaps the real collectors for the
/// invented preview data: a test-only path that touches no agent, Keychain or network.
enum CLI {
    static let usage = """
    \(AppInfo.name) \(AppInfo.version) — AI agent limits in the menu bar.

    Usage: agentic-apple [option]

      (no option)              start the menu bar app
      --text                   print one line per agent shown in the bar
      --json                   print every detected agent and its limit windows as JSON
      --render-preview <dir>   write preview PNGs from invented data (bar and panel, light and dark)
      --unregister-login-item  remove the launch-at-login item (run from the installed app)
      --version                print the version
      --help                   show this help

    --text and --json read the same settings as the app (order, show switches,
    thresholds, command paths) and never print a key or token.
    """

    /// nil = no CLI mode, start the app.
    static func run(_ args: [String]) -> Int32? {
        let fixture = args.contains("--fixture") || ProcessInfo.processInfo.environment["AGENTIC_APPLE_FIXTURE"] == "1"
        let rest = args.filter { $0 != "--fixture" }
        guard let first = rest.first else {
            if args.contains("--fixture") {
                FileHandle.standardError.write(Data("--fixture goes with --text or --json\n".utf8))
                return 64
            }
            return nil
        }
        switch first {
        case "--help", "-h":
            print(usage)
            return 0
        case "--version", "-v":
            print("\(AppInfo.name) \(AppInfo.version)")
            return 0
        case "--unregister-login-item":
            guard LoginItem.isAvailable else {
                FileHandle.standardError.write(Data("--unregister-login-item only works from the installed app bundle\n".utf8))
                return 1
            }
            if LoginItem.unregister() {
                print("Login item removed")
                return 0
            }
            return 1
        case "--text":
            guard let collected = collect(fixture: fixture) else { return 1 }
            let (providers, history) = collected
            let s = SettingsSnapshot.read(AppInfo.defaults)
            var state = DisplayState()
            state.providers = providers
            state.history = history
            state.order = s.providerOrder
            state.visibility = s.visibility
            state.warn = Double(s.warnPercent)
            state.critical = Double(s.criticalPercent)
            let lines = state.textLines
            print(lines.isEmpty ? "no agents" : lines.joined(separator: "\n"))
            return 0
        case "--json":
            guard let collected = collect(fixture: fixture) else { return 1 }
            let (providers, history) = collected
            let s = SettingsSnapshot.read(AppInfo.defaults)
            print(json(providers: providers, history: history, settings: s,
                       now: fixture ? PreviewFixture.now : Date().timeIntervalSince1970 * 1000))
            return 0
        case "--render-preview":
            guard rest.count >= 2, !rest[1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--render-preview needs a directory\n".utf8))
                return 64
            }
            let dir = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath)
            return MainActor.assumeIsolated {
                do {
                    let files = try PreviewRenderer.render(to: dir)
                    for f in files { print(f.path) }
                    return 0
                } catch {
                    FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                    return 1
                }
            }
        default:
            if first.hasPrefix("-psn_") { return nil }   // Finder's process serial number
            if first.hasPrefix("-") {
                FileHandle.standardError.write(Data("Unknown option \(first)\n\n\(usage)\n".utf8))
                return 64
            }
            return nil
        }
    }

    /// Collect once (blocking). History comes from the app's cache, read-only,
    /// so OpenRouter's figures match the bar. nil (after printing an error) when
    /// the collection does not finish within `collectTimeout`.
    static let collectTimeout: TimeInterval = 120

    static func collect(fixture: Bool) -> ([Provider], CycleHistory)? {
        if fixture { return (PreviewFixture.providers, .empty) }
        let now = Date()
        let history = UsageCache.read(from: AppInfo.cacheURL, now: now.timeIntervalSince1970 * 1000)?.history ?? .empty
        let settings = SettingsSnapshot.read(AppInfo.defaults)
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let resolved = await Store.resolveEnvironment(timeout: Store.environmentTimeout)
            var context = settings.context(searchPath: resolved.searchPath)
            context.environment = resolved.environment
            let providers = await Collector.live().collect(context)
            box.set(providers)
            done.signal()
        }
        guard done.wait(timeout: .now() + collectTimeout) == .success else {
            FileHandle.standardError.write(Data("Agents took too long to answer (no result after \(Int(collectTimeout)) s)\n".utf8))
            return nil
        }
        let fresh = box.get()
        return (fresh, history.advanced(with: fresh.first { $0.id == .openrouter }?.money, now: now.timeIntervalSince1970 * 1000))
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Provider] = []
        func set(_ v: [Provider]) { lock.lock(); value = v; lock.unlock() }
        func get() -> [Provider] { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: JSON

    struct WindowOut: Encodable {
        var key, label, short, detail: String
        var percent: Double
        var resetsAt: Double
        var stale, limited: Bool
        var state, color, mode: String
        var value: String
        var caption: String
    }

    struct ProviderOut: Encodable {
        var provider: Provider
        var shown: Bool
        var windows: [WindowOut]
        enum CodingKeys: String, CodingKey { case id, name, available, shown, tier, status, hint, error, source, limits, activity, money, budgets, readAt, windows }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider.id, forKey: .id)
            try c.encode(provider.name, forKey: .name)
            try c.encode(provider.available, forKey: .available)
            try c.encode(shown, forKey: .shown)
            try c.encode(provider.tier, forKey: .tier)
            try c.encode(provider.status, forKey: .status)
            try c.encode(provider.hint, forKey: .hint)
            try c.encode(provider.error, forKey: .error)
            try c.encode(provider.source, forKey: .source)
            try c.encode(provider.limits, forKey: .limits)
            try c.encode(provider.activity, forKey: .activity)
            try c.encodeIfPresent(provider.money, forKey: .money)
            try c.encode(provider.budgets, forKey: .budgets)
            try c.encode(provider.readAt, forKey: .readAt)
            try c.encode(windows, forKey: .windows)
        }
    }

    struct Document: Encodable {
        var app: String
        var version: String
        var generatedAt: Double
        var providers: [ProviderOut]
    }

    static func json(providers: [Provider], history: CycleHistory, settings: SettingsSnapshot, now: Double) -> String {
        let warn = Double(settings.warnPercent), critical = Double(settings.criticalPercent)
        // UsageCache.slim re-sanitises every string; providers never carry key material.
        let out = providers.map(UsageCache.slim).map { p in
            ProviderOut(provider: p, shown: settings.visibility[p.id] != false,
                        windows: Meters.windowsFor(p, history: history, warn: warn, critical: critical).map { w in
                            WindowOut(key: w.key, label: w.label, short: w.short, detail: w.detail,
                                      percent: w.percent, resetsAt: w.resetsAt, stale: w.stale, limited: w.limited,
                                      state: w.state.rawValue, color: w.color.rawValue, mode: w.mode.rawValue,
                                      value: Summary.windowValueText(w), caption: Summary.windowCaption(w, now: now))
                        })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "0", negativeInfinity: "0", nan: "0")
        let doc = Document(app: AppInfo.name, version: AppInfo.version, generatedAt: now, providers: out)
        guard let data = try? encoder.encode(doc) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
