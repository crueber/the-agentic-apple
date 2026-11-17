import Darwin
import Foundation

/// Check → download → verify + stage, wired together for the app. The swap
/// (`UpdateInstaller.swap`) and the relaunch are separate steps, so the app can
/// wait for an in-flight collection between staging and replacing itself.
///
/// Public API:
/// - `UpdateEngine(http:feedURL:downloader:installer:)`
/// - `check() async -> Result<UpdateCheckResult, UpdateError>` (no trusted keys:
///   `.notConfigured`, without touching the network)
/// - `prepare(_:) async throws -> URL` — download both assets into a fresh 0700
///   folder, verify, stage; returns the staged app
/// - `discard(staged:)`
///
/// The shipped app builds it only from constants (`UpdateFeed.feedURL`,
/// `HTTPClient.live`, `UpdateKeys.trusted`); the injectable pieces are for the self-test.
public struct UpdateEngine: Sendable {
    public var http: HTTPClient
    public var feedURL: String
    public var downloader: UpdateDownloader
    public var installer: UpdateInstaller

    public init(http: HTTPClient, feedURL: String = UpdateFeed.feedURL,
                downloader: UpdateDownloader = UpdateDownloader(), installer: UpdateInstaller) {
        self.http = http
        self.feedURL = feedURL
        self.downloader = downloader
        self.installer = installer
    }

    public var isConfigured: Bool { UpdateSignature.isConfigured(installer.config.trustedKeys) }

    public func check() async -> Result<UpdateCheckResult, UpdateError> {
        guard isConfigured else { return .failure(.notConfigured) }
        return await UpdateFeed.fetch(http: http, feedURL: feedURL, currentVersion: installer.config.currentVersion)
    }

    public func prepare(_ release: UpdateRelease) async throws -> URL {
        guard isConfigured else { throw UpdateError.notConfigured }
        let installer = self.installer
        let work = try installer.makeWorkDirectory()
        do {
            let sigURL = work.appendingPathComponent("update.dmg.sig")
            let dmgURL = work.appendingPathComponent("update.dmg")
            try await downloader.download(release.signature.url, to: sigURL,
                                          maxBytes: UpdateFeed.maxSignatureBytes, expectedSize: release.signature.size)
            try await downloader.download(release.dmg.url, to: dmgURL,
                                          maxBytes: UpdateFeed.maxDMGBytes, expectedSize: release.dmg.size)
            guard let sig = UpdateInstaller.readRegularFile(sigURL, maxBytes: UpdateFeed.maxSignatureBytes) else {
                throw UpdateError.badSignature
            }
            let version = release.version.text
            let result: Result<URL, Error> = await Blocking.run {
                Result { try installer.stage(dmg: dmgURL, signatureFile: sig, expectedVersion: version, workDirectory: work) }
            }
            await Blocking.run { UpdateInstaller.removeWorkDirectory(work) }
            return try result.get()
        } catch {
            await Blocking.run { UpdateInstaller.removeWorkDirectory(work) }
            throw error
        }
    }

    public func discard(staged: URL) {
        let base = installer.config.installedApp.deletingPathExtension().lastPathComponent
        guard UpdateInstaller.isStagingName(staged.lastPathComponent, appBase: base) else { return }
        UpdateInstaller.removeTree(staged)
    }
}

/// The relaunch helper: a detached `/bin/sh` with a fixed script that waits
/// (bounded) for `pid` to exit, then `open`s the installed app. Every value is
/// a positional argument, never part of the script text.
public enum UpdateRelaunch {
    static let script = """
    pid="$1"; shift
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.2; i=$((i+1)); done
    exec "$@"
    """

    /// Arguments for `/bin/sh` (exposed for the self-test).
    public static func arguments(pid: Int32, appPath: String, fixture: Bool, opener: String = "/usr/bin/open") -> [String] {
        var args = ["-c", script, "agentic-apple-relaunch", String(pid), opener]
        if fixture { args += ["--env", "AGENTIC_APPLE_FIXTURE=1"] }
        args.append(appPath)
        return args
    }

    /// Start the helper in its own session with stdio on /dev/null. True when it started.
    @discardableResult
    public static func spawn(waitingFor pid: Int32, appPath: String, fixture: Bool,
                             opener: String = "/usr/bin/open") -> Bool {
        let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { return false }
        defer { Darwin.close(null) }
        let env = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        return (try? Spawn.spawn("/bin/sh", arguments(pid: pid, appPath: appPath, fixture: fixture, opener: opener),
                                 environment: env, stdin: null, stdout: null, stderr: null,
                                 newSession: true)) != nil
    }
}
