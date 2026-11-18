import AppKit
import AgenticCore

/// Self-update for the installed app (core pipeline: `AgenticCore/Update/`).
///
/// - Runs only in the bundled app (never `swift run`, the CLI modes or the
///   self-test) and only with at least one key in `UpdateKeys.trusted`;
///   otherwise it reports "Updates not configured" and never touches the network.
/// - Automatic checks (when `autoUpdate` is on): ~2 minutes after launch, then
///   every 6 hours, and on wake when the last check is older than 6 hours.
///   With `autoUpdate` off there is no automatic network traffic; "Check for
///   Updates" still works and offers "Install Now".
/// - Installs only into an installed copy (/Applications or ~/Applications) in
///   a writable folder; anywhere else it points at the release page.
/// - Download, verification and staging run any time; the swap and relaunch
///   wait until no collection is in flight, and fetches are held from then on.
/// - The new version, at launch, removes the backup and staging folders beside
///   itself and shows "Updated to X" once.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case updating(String)
        case available(version: String, page: URL, canInstall: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            switch phase {
            case .idle, .checking: break
            case .updating(let v): UpdateLog.write("installing \(v)")
            case .available(let v, _, let canInstall): UpdateLog.write("\(v) available\(canInstall ? "" : " (cannot install here)")")
            case .failed(let m): UpdateLog.write("update: \(m)")
            }
        }
    }
    @Published private(set) var lastCheck: Date?
    @Published private(set) var now = Date()

    private let settings: AppSettings
    private let store: Store
    private let engine: UpdateEngine
    private var pending: UpdateRelease?
    private var scheduleTask: Task<Void, Never>?
    /// The launch-time removal of leftover backups; an install waits for it so
    /// it can never remove a staging copy that is about to be swapped in.
    private var cleanupTask: Task<Void, Never>?
    private var running = false

    static let firstCheckDelay: TimeInterval = 120
    static let checkInterval: TimeInterval = 6 * 3600
    static let collectionWait: TimeInterval = 300
    static let cleanupDelay: TimeInterval = 10
    enum Keys {
        static let lastCheck = "updateLastCheck"
        /// Written just before relaunching into a new version; read once by it.
        static let installedVersion = "updateInstalledVersion"
    }

    init(settings: AppSettings, store: Store) {
        self.settings = settings
        self.store = store
        // Constants only: no runtime override of the feed, keys or install path.
        engine = UpdateEngine(http: .live, feedURL: UpdateFeed.feedURL, installer: UpdateInstaller(.init(
            installedApp: Bundle.main.bundleURL, currentVersion: AppInfo.version,
            bundleID: AppInfo.bundleID, trustedKeys: UpdateKeys.trusted)))
        let t = settings.defaults.double(forKey: Keys.lastCheck)
        if t > 0 { lastCheck = Date(timeIntervalSince1970: t) }
    }

    /// The bundled app; `swift run` and the CLI never update.
    var isSupported: Bool { AppInfo.isBundled }
    var isConfigured: Bool { engine.isConfigured }
    var canCheck: Bool { isSupported && isConfigured && !running }
    /// An installed copy whose folder we can write: the only place we replace ourselves.
    var canInstallInPlace: Bool { LoginItem.isInstalledCopy && UpdateInstaller.canReplace(Bundle.main.bundleURL) }

    // MARK: lifecycle

    func start() {
        guard isSupported else { return }
        let defaults = settings.defaults
        if let installed = defaults.string(forKey: Keys.installedVersion) {
            defaults.removeObject(forKey: Keys.installedVersion)
            if installed == AppInfo.version { store.setUpdateNote("Updated to \(installed)") }
        }
        if LoginItem.isInstalledCopy {
            let app = Bundle.main.bundleURL
            cleanupTask = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(Self.cleanupDelay * 1_000_000_000))
                UpdateInstaller.cleanupLeftovers(beside: app)
            }
        }
        guard isConfigured else { return }
        schedule(after: Self.firstCheckDelay)
    }

    private func schedule(after seconds: TimeInterval) {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.settings.autoUpdate { await self.check(manual: false) }
            self.schedule(after: Self.checkInterval)
        }
    }

    /// Back from sleep: check when the last one is older than the interval.
    func didWake() {
        guard isSupported, isConfigured, settings.autoUpdate else { return }
        let age = lastCheck.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > Self.checkInterval { schedule(after: 30) }
    }

    // MARK: actions

    func checkNow() {
        guard canCheck else { return }
        Task { await check(manual: true) }
    }

    /// "Install Now" for an update found while automatic installs are off.
    func installPending() {
        guard let release = pending, !running, canInstallInPlace else { return }
        Task { await install(release) }
    }

    private func check(manual: Bool) async {
        guard canCheck else { return }
        running = true
        phase = .checking
        let result = await engine.check()
        lastCheck = Date()
        now = Date()
        settings.defaults.set(lastCheck!.timeIntervalSince1970, forKey: Keys.lastCheck)
        running = false
        switch result {
        case .success(.upToDate):
            pending = nil
            phase = .idle
        case .success(.rejected(let message)):
            pending = nil
            phase = .failed(message)
        case .success(.available(let release)):
            pending = release
            let installable = canInstallInPlace
            phase = .available(version: release.version.text, page: release.pageURL, canInstall: installable)
            if installable && settings.autoUpdate { await install(release) }
        case .failure(let error):
            pending = nil
            phase = .failed(error.description)
        }
    }

    private func install(_ release: UpdateRelease) async {
        guard !running, canInstallInPlace else { return }
        running = true
        defer { running = false }
        let version = release.version.text
        phase = .updating(version)
        await cleanupTask?.value
        let engine = self.engine
        let staged: URL
        do {
            staged = try await engine.prepare(release)
        } catch {
            phase = .failed(Self.words(error))
            return
        }

        // Swap only between collections; hold new ones until we quit.
        store.holdFetches(true)
        let deadline = Date().addingTimeInterval(Self.collectionWait)
        while store.isCollecting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if store.isCollecting {
            // Never swap under a running collection; the next check retries.
            await Blocking.run { engine.discard(staged: staged) }
            store.holdFetches(false)
            phase = .failed("The update waited too long for a refresh to finish; it will try again later")
            return
        }
        let result: Result<URL, Error> = await Blocking.run {
            Result { try engine.installer.swap(staged: staged) }
        }
        if case .failure(let error) = result {
            await Blocking.run { engine.discard(staged: staged) }
            store.holdFetches(false)
            phase = .failed(Self.words(error))
            return
        }

        settings.defaults.set(version, forKey: Keys.installedVersion)
        settings.defaults.synchronize()
        UpdateLog.write("swapped in \(version); relaunching")
        guard await Self.relaunch() else {
            // The new version is in place; it starts next time.
            UpdateLog.write("relaunch could not be started; waiting for a manual reopen")
            store.holdFetches(false)
            phase = .failed("Updated to \(version); quit and reopen the app to finish")
            return
        }
        UpdateLog.write("quitting so the new version can take over")
        NSApp.terminate(nil)
    }

    /// Environment variable carrying the old instance's PID to the new one,
    /// which waits for that PID to exit before its single-instance check.
    /// (An environment variable, not an argument: arguments are CLI modes.)
    static let relaunchAfterKey = "AGENTIC_APPLE_RELAUNCH_AFTER"

    /// Launch the freshly swapped-in bundle as a new instance through
    /// LaunchServices, before quitting. The new instance waits for this
    /// process to exit. Falls back to the detached shell helper if
    /// LaunchServices refuses. True when something was started.
    private static func relaunch() async -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let fixture = ProcessInfo.processInfo.environment["AGENTIC_APPLE_FIXTURE"] == "1"
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        var env = [relaunchAfterKey: String(pid)]
        if fixture { env["AGENTIC_APPLE_FIXTURE"] = "1" }
        config.environment = env
        let appURL = Bundle.main.bundleURL
        let launched: Bool = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                if let error {
                    UpdateLog.write("LaunchServices relaunch failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    UpdateLog.write("new instance launched (pid \(app?.processIdentifier ?? 0))")
                    continuation.resume(returning: true)
                }
            }
        }
        if launched { return true }
        let helper = UpdateRelaunch.spawn(waitingFor: pid, appPath: appURL.path, fixture: fixture)
        UpdateLog.write(helper ? "fell back to the relaunch helper" : "relaunch helper could not start")
        return helper
    }

    private static func words(_ error: Error) -> String {
        (error as? UpdateError)?.description ?? "The update failed"
    }

    // MARK: display

    /// The newer release's page, while one is known (available, or its install failed).
    var releasePage: URL? {
        switch phase {
        case .available(_, let page, _): return page
        case .failed: return pending?.pageURL
        default: return nil
        }
    }

    /// "Install Now" applies: an installable update found while automatic installs are off.
    var offersInstall: Bool {
        if case .available(_, _, true) = phase { return !settings.autoUpdate && !running }
        return false
    }

    func statusText(now: Date) -> String {
        guard isSupported else { return "Updates work in the installed app" }
        guard isConfigured else { return "Updates not configured" }
        switch phase {
        case .checking: return "Checking for updates…"
        case .updating(let v): return "Updating to \(v)…"
        case .available(let v, _, let canInstall):
            if canInstall { return settings.autoUpdate ? "Update \(v) available" : "Update \(v) available — Install Now to update" }
            if LoginItem.isInstalledCopy { return "Update \(v) available — this folder is not writable; download it from the release page" }
            return "Update \(v) available — move the app to Applications to update automatically"
        case .failed(let message): return message + checkedSuffix(now)
        case .idle:
            guard lastCheck != nil else { return settings.autoUpdate ? "Not checked yet" : "Automatic checks are off" }
            return "Up to date" + checkedSuffix(now)
        }
    }

    private func checkedSuffix(_ now: Date) -> String {
        guard let lastCheck else { return "" }
        let ago = Format.updatedAgo(lastCheck.timeIntervalSince1970 * 1000, now: now.timeIntervalSince1970 * 1000)
        return ago.isEmpty ? "" : " · checked \(ago)"
    }
}
