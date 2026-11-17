import AppKit
import Combine
import AgenticCore

/// App state and the fetch lifecycle (README "How it fetches"):
/// - paint the cached result immediately, then wait out the rest of the interval
///   (`Schedule.autoDelayMs`);
/// - the search PATH is resolved once, off the main thread, before the first fetch;
/// - collection runs detached (Shell.run blocks a thread), bounded by a timeout;
/// - a fresh result is merged over the previous one (`ProviderMerge`), OpenRouter's
///   cycle history advances, and the cache is written after every attempt;
/// - manual refresh at most every 30 s, automatic every `refreshIntervalSec`,
///   failures back off 1 → 10 min; refresh on wake and when the panel opens stale.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var history: CycleHistory = .empty
    @Published private(set) var lastFetchMs: Double = 0
    @Published private(set) var lastAttemptMs: Double = 0
    @Published private(set) var failures = 0
    @Published private(set) var lastError = ""
    @Published private(set) var busy = false
    @Published private(set) var now = Date().timeIntervalSince1970 * 1000
    @Published private(set) var searchPathReady = false

    let settings: AppSettings
    let cacheURL: URL
    private let collector: Collector
    private var searchPath: [String] = []
    private var pendingFetch: Bool?          // manual? — requested before PATH was ready
    private var pollTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Whole collection is abandoned after this long (each source has its own shorter timeouts).
    static let collectTimeout: TimeInterval = 90

    init(settings: AppSettings, cacheURL: URL = AppInfo.cacheURL, collector: Collector = .live()) {
        self.settings = settings
        self.cacheURL = cacheURL
        self.collector = collector
        settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.$refreshIntervalSec.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleNextPoll() } }
            .store(in: &cancellables)
    }

    var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: lifecycle

    func start() {
        loadCache()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tickTimer?.tolerance = 5
        let env = ProcessInfo.processInfo.environment
        Task.detached(priority: .utility) {
            let path = SearchPath.resolve(home: FileManager.default.homeDirectoryForCurrentUser, environment: env)
            await MainActor.run { self.searchPathResolved(path) }
        }
    }

    private func searchPathResolved(_ path: [String]) {
        searchPath = path
        searchPathReady = true
        if let manual = pendingFetch {
            pendingFetch = nil
            requestFetch(manual: manual)
        } else if providers.isEmpty {
            requestFetch(manual: false)
        } else {
            scheduleNextPoll()
        }
    }

    func tick() { now = nowMs }

    private func loadCache() {
        guard let cached = UsageCache.read(from: cacheURL, now: nowMs) else { return }
        lastFetchMs = max(lastFetchMs, cached.fetchedAt)
        lastAttemptMs = max(lastAttemptMs, cached.attemptedAt)
        failures = max(failures, cached.failures)
        history = cached.history
        lastError = cached.error
        if !cached.providers.isEmpty { providers = cached.providers }
        now = nowMs
    }

    private func writeCache() {
        let cache = UsageCache(providers: providers, history: history, fetchedAt: lastFetchMs,
                               attemptedAt: lastAttemptMs, failures: failures, error: lastError)
        try? cache.write(to: cacheURL)
    }

    // MARK: fetching

    /// Manual: refresh button, `r`, middle click, menu. Throttled to one every 30 s.
    func refreshNow() { requestFetch(manual: true) }

    func requestFetch(manual: Bool) {
        guard searchPathReady else {
            pendingFetch = (pendingFetch ?? false) || manual
            return
        }
        guard !busy else { return }
        guard Schedule.canFetch(lastAttemptMs: lastAttemptMs, now: nowMs, manual: manual) else {
            if !manual { scheduleNextPoll() }
            return
        }
        spawnFetch()
    }

    private func spawnFetch() {
        busy = true
        lastAttemptMs = nowMs
        writeCache()
        let context = settings.snapshot.context(searchPath: searchPath)
        let collector = self.collector
        Task {
            let fresh = await Self.collect(collector, context, timeout: Self.collectTimeout)
            self.apply(fresh)
        }
    }

    /// Runs the collectors off the main actor; nil when they ran out of time.
    /// A real race: the caller resumes at the timeout even though a stuck source
    /// (Shell.run blocks its thread) keeps running until its own timeout.
    nonisolated static func collect(_ collector: Collector, _ context: CollectorContext,
                                    timeout: TimeInterval) async -> [Provider]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Provider]?, Never>) in
            let once = ResumeOnce(continuation)
            Task.detached(priority: .userInitiated) { once.resume(await collector.collect(context)) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    private func apply(_ fresh: [Provider]?) {
        busy = false
        let t = nowMs
        guard let fresh else {
            handleFailure("Agents took too long to answer")
            return
        }
        let merged = ProviderMerge.merge(previous: providers, fresh: fresh)
        providers = merged
        history = history.advanced(with: merged.first { $0.id == .openrouter }?.money, now: t)
        // A global failure (for backoff) is every detected agent failing at once —
        // typically no network. One agent's error is shown on its own row instead.
        let available = merged.filter(\.available)
        if !available.isEmpty, available.allSatisfy({ !$0.error.isEmpty }) {
            handleFailure("Every agent failed to answer")
            return
        }
        lastFetchMs = t
        failures = 0
        lastError = ""
        now = t
        writeCache()
        scheduleNextPoll()
    }

    private func handleFailure(_ message: String) {
        failures = Schedule.nextFailures(failures)
        lastError = String(message.prefix(240))
        now = nowMs
        writeCache()
        scheduleNextPoll()
    }

    func scheduleNextPoll() {
        pollTask?.cancel()
        let delay = Schedule.autoDelayMs(fetchedAt: lastFetchMs, attemptedAt: lastAttemptMs, failures: failures,
                                         refreshMs: Double(settings.refreshIntervalSec) * 1000, now: nowMs)
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(250, delay) * 1_000_000))
            guard !Task.isCancelled else { return }
            self?.requestFetch(manual: false)
        }
    }

    /// The panel opened: refresh relative times, and fetch when older than the interval.
    func panelOpened() {
        now = nowMs
        if lastFetchMs > 0, nowMs - lastFetchMs > Double(settings.refreshIntervalSec) * 1000 {
            requestFetch(manual: false)
        }
    }

    /// Back from sleep: give the network a moment, then refresh.
    func didWake() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.now = Date().timeIntervalSince1970 * 1000
            self?.requestFetch(manual: false)
        }
    }

    // MARK: order and switches

    func setShown(_ id: ProviderID, _ shown: Bool) { settings.setShown(id, shown) }

    /// Drop `id` at `insertIndex` among the panel rows (switched-off agents included).
    func reorder(_ id: ProviderID, to insertIndex: Int) {
        let visibleIDs = display.panelProviders.map(\.id)
        let next = Ordering.reorderInsert(settings.providerOrder, visibleIDs: visibleIDs, id: id, insertIndex: insertIndex)
        settings.providerOrder = Ordering.serializeOrder(next)
    }

    // MARK: cache management

    func clearCache() {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheURL)
        try? fm.removeItem(at: cacheURL.deletingLastPathComponent().appendingPathComponent("claude-activity.json"))
        history = .empty
    }

    // MARK: snapshot

    var display: DisplayState {
        var s = DisplayState()
        s.providers = providers
        s.history = history
        s.order = settings.providerOrder
        s.visibility = settings.visibility
        s.warn = Double(settings.warnPercent)
        s.critical = Double(settings.criticalPercent)
        s.showActivity = settings.showActivity
        s.barStyle = settings.barStyle
        s.palette = Palette(warningHex: settings.warningColor.isEmpty ? nil : settings.warningColor,
                            criticalHex: settings.criticalColor.isEmpty ? nil : settings.criticalColor)
        s.now = now
        s.lastFetchMs = lastFetchMs
        s.lastError = lastError
        s.busy = busy
        s.looking = providers.isEmpty && (lastFetchMs == 0 || !searchPathReady)
        return s
    }
}

/// Resumes a continuation exactly once, from whichever task gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Provider]?, Never>?
    init(_ c: CheckedContinuation<[Provider]?, Never>) { continuation = c }
    func resume(_ value: [Provider]?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
