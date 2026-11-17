import AppKit
import Combine
import AgenticCore

/// App state and the fetch lifecycle (README "How it fetches"):
/// - paint the cached result immediately, then wait out the rest of the interval
///   (`Schedule.autoDelayMs`);
/// - the search PATH and the shell variables collectors read are resolved once,
///   off the main thread, before the first fetch (`SearchPath.resolveEnvironment`,
///   raced against `environmentTimeout`; on expiry the process environment and the
///   well-known dirs are used);
/// - collection runs detached (Shell.run blocks a thread). After `collectTimeout`
///   the attempt counts as failed, but no new collection starts until the
///   abandoned one has really finished (its late result is still merged);
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
    private let makeCollector: @Sendable () -> Collector
    private var collector: Collector
    private var searchPath: [String] = []
    private var environment: [String: String] = ProcessInfo.processInfo.environment
    /// A collection is actually running (stays true past the timeout until it returns).
    private var collecting = false
    /// Identifies the current attempt; a result or timeout for an older one is ignored.
    private var fetchGeneration = 0
    /// Set when a fetch was wanted while an abandoned collection was still running.
    private var fetchAfterCollect: Bool?
    /// Clear Cache ran while a collection was in flight; its old activity store may
    /// write `claude-activity.json` back when it returns, so clear again then.
    private var clearAfterCollect = false
    private var timeoutTask: Task<Void, Never>?
    private var pendingFetch: Bool?          // manual? — requested before PATH was ready
    private var pollTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Whole collection is abandoned after this long (each source has its own shorter timeouts).
    nonisolated static let collectTimeout: TimeInterval = 90
    /// The login-shell probe is given this long before falling back to the process environment.
    nonisolated static let environmentTimeout: TimeInterval = 10

    /// `makeCollector` is called again by `clearCache`, so Claude's activity store starts empty.
    init(settings: AppSettings, cacheURL: URL = AppInfo.cacheURL,
         makeCollector: @escaping @Sendable () -> Collector = { .live() }) {
        self.settings = settings
        self.cacheURL = cacheURL
        self.makeCollector = makeCollector
        self.collector = makeCollector()
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
        Task { [weak self] in
            let resolved = await Self.resolveEnvironment(timeout: Self.environmentTimeout)
            self?.environmentResolved(resolved)
        }
    }

    /// Login-shell PATH and allowlisted variables, or — when the shell does not
    /// answer within `timeout` — the process environment plus the well-known dirs.
    nonisolated static func resolveEnvironment(timeout: TimeInterval) async -> (searchPath: [String], environment: [String: String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let fallback = SearchPath.resolveEnvironment(home: home, environment: env, includeLoginShell: false)
        return await race(timeout: timeout, fallback: fallback) {
            SearchPath.resolveEnvironment(home: home, environment: env)
        }
    }

    private func environmentResolved(_ resolved: (searchPath: [String], environment: [String: String])) {
        searchPath = resolved.searchPath
        environment = resolved.environment
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
        guard !collecting else {
            // The previous (timed-out) collection is still running; fetch once it returns.
            fetchAfterCollect = (fetchAfterCollect ?? false) || manual
            return
        }
        guard Schedule.canFetch(lastAttemptMs: lastAttemptMs, now: nowMs, manual: manual) else {
            if !manual { scheduleNextPoll() }
            return
        }
        spawnFetch()
    }

    private func spawnFetch() {
        busy = true
        collecting = true
        fetchGeneration += 1
        let generation = fetchGeneration
        lastAttemptMs = nowMs
        writeCache()
        var context = settings.snapshot.context(searchPath: searchPath)
        context.environment = environment
        let collector = self.collector
        Task.detached(priority: .userInitiated) { [weak self] in
            let fresh = await collector.collect(context)
            await self?.collectionFinished(fresh, generation: generation)
        }
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.collectTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.collectionTimedOut(generation: generation)
        }
    }

    /// The collectors returned — possibly long after the timeout.
    private func collectionFinished(_ fresh: [Provider], generation: Int) {
        collecting = false
        let current = generation == fetchGeneration
        if current {
            timeoutTask?.cancel()
            timeoutTask = nil
            busy = false
            apply(fresh)
            // The late result is as fresh as an automatic fetch would be.
            if fetchAfterCollect == false { fetchAfterCollect = nil }
        }
        if clearAfterCollect {
            clearAfterCollect = false
            removeCacheFiles()
            collector = makeCollector()
        }
        if let manual = fetchAfterCollect {
            fetchAfterCollect = nil
            requestFetch(manual: manual)
        }
    }

    /// The attempt counts as failed; the collection itself keeps running (a stuck
    /// source holds its thread until its own timeout), so `collecting` stays set.
    private func collectionTimedOut(generation: Int) {
        guard generation == fetchGeneration, busy else { return }
        busy = false
        handleFailure("Agents took too long to answer")
    }

    private func apply(_ fresh: [Provider]) {
        let t = nowMs
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

    /// Forget everything shown and cached, Claude's activity scan included (a new
    /// collector gets an empty activity store), then fetch afresh. A collection
    /// still in flight is abandoned: its result is dropped, and the fresh fetch
    /// starts as soon as it has returned.
    func clearCache() {
        fetchGeneration += 1                // drop any in-flight result
        timeoutTask?.cancel()
        timeoutTask = nil
        busy = false
        if collecting { clearAfterCollect = true }
        removeCacheFiles()
        collector = makeCollector()
        providers = []
        history = .empty
        lastFetchMs = 0
        lastAttemptMs = 0
        failures = 0
        lastError = ""
        now = nowMs
        requestFetch(manual: true)
    }

    private func removeCacheFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheURL)
        try? fm.removeItem(at: cacheURL.deletingLastPathComponent().appendingPathComponent("claude-activity.json"))
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

/// Runs `work` on a detached thread and returns its value, or `fallback` when it
/// has not finished within `timeout` (the work keeps running to its own end).
func race<T: Sendable>(timeout: TimeInterval, fallback: T, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let once = ResumeOnce(continuation)
        Task.detached(priority: .userInitiated) { once.resume(work()) }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            once.resume(fallback)
        }
    }
}

/// Resumes a continuation exactly once, from whichever task gets there first.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
