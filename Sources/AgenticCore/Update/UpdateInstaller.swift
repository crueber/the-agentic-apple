import Darwin
import Foundation

/// Verifies, stages and swaps in a downloaded update. AppKit-free; every path,
/// key and version comes from `Configuration`, which the app fills from its
/// own bundle and `UpdateKeys.trusted` (tests pass their own).
///
/// Public API:
/// - `UpdateInstaller(_:)`, `Configuration`
/// - `makeWorkDirectory()` — a fresh 0700 directory for downloads and the mount point
/// - `stage(dmg:signatureFile:expectedVersion:workDirectory:)` → staged app beside the installed one
/// - `swap(staged:)` → backup URL; `install(…)` = stage + swap
/// - `canReplace(_:)`, `isStagingName(_:appBase:)`, `isBackupName(_:appBase:)`,
///   `cleanupLeftovers(beside:)`
///
/// Staging, in order — any failure stops it, removes the staged copy and leaves
/// the installed app untouched:
/// 1. the DMG on disk is read once and its Ed25519 signature checked against the
///    trusted keys (no keys: `.notConfigured`) — before anything mounts it;
/// 2. `hdiutil attach -readonly -nobrowse -noautoopen` at a private mount point
///    (always detached again);
/// 3. exactly one `.app` (a real directory, not a symlink) at the volume's top;
/// 4. its Info.plist: `CFBundleIdentifier` == ours, `CFBundleShortVersionString`
///    == the feed's version and strictly newer than the running one, a plain
///    `CFBundleExecutable`;
/// 5. `codesign --verify --deep --strict` on the mounted app;
/// 6. `ditto --noqtn` to `.<App>.update-<8 hex>.app` beside the installed app
///    (same volume, so the swap is a rename); `com.apple.quarantine` removed;
///    `codesign --verify` again;
/// 7. the staged executable's `--version` must print the expected version.
public struct UpdateInstaller: Sendable {
    public struct Configuration: Sendable {
        public var installedApp: URL
        public var currentVersion: String
        public var bundleID: String
        public var trustedKeys: [String]
        /// Parent of the fresh work directories (downloads, mount point).
        public var workRoot: URL
        public var toolTimeout: TimeInterval
        /// Self-test only: skip the atomic `RENAME_SWAP` and use the two-rename fallback.
        public var forceTwoStepSwap: Bool

        public init(installedApp: URL, currentVersion: String, bundleID: String, trustedKeys: [String],
                    workRoot: URL = FileManager.default.temporaryDirectory, toolTimeout: TimeInterval = 120,
                    forceTwoStepSwap: Bool = false) {
            self.installedApp = installedApp
            self.currentVersion = currentVersion
            self.bundleID = bundleID
            self.trustedKeys = trustedKeys
            self.workRoot = workRoot
            self.toolTimeout = toolTimeout
            self.forceTwoStepSwap = forceTwoStepSwap
        }
    }

    public let config: Configuration
    public init(_ config: Configuration) { self.config = config }

    static let hdiutil = "/usr/bin/hdiutil"
    static let codesign = "/usr/bin/codesign"
    static let ditto = "/usr/bin/ditto"
    static let quarantine = "com.apple.quarantine"
    static let toolEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]

    // MARK: work directory

    /// A new 0700 directory under `workRoot`; the caller removes it.
    public func makeWorkDirectory() throws -> URL {
        let dir = config.workRoot.appendingPathComponent("agentic-apple-update-\(Self.token())", isDirectory: true)
        guard Darwin.mkdir(dir.path, 0o700) == 0 else { throw UpdateError.install("Could not create a private work folder") }
        return dir
    }

    // MARK: stage

    /// Verify `dmg` with `signatureFile` (the `.sig` asset's bytes) and stage its app.
    /// Returns the staged app's URL beside the installed app.
    public func stage(dmg: URL, signatureFile: Data, expectedVersion: String, workDirectory: URL) throws -> URL {
        guard UpdateSignature.isConfigured(config.trustedKeys) else { throw UpdateError.notConfigured }
        guard let expected = UpdateVersion(expectedVersion), let current = UpdateVersion(config.currentVersion) else {
            throw UpdateError.badBundle("The update's version is not usable")
        }
        guard expected > current else { throw UpdateError.badBundle("The update is not newer than this copy") }

        // 1. Signature over the exact bytes of the file that will be mounted.
        guard let signature = UpdateSignature.decodeSignature(signatureFile) else { throw UpdateError.badSignature }
        guard let bytes = Self.readRegularFile(dmg, maxBytes: UpdateFeed.maxDMGBytes) else {
            throw UpdateError.badImage("The downloaded disk image could not be read")
        }
        guard UpdateSignature.verify(bytes, signature: signature, trustedKeys: config.trustedKeys) else {
            throw UpdateError.badSignature
        }

        // 2. Mount read-only at a private mount point; always detach.
        let mount = workDirectory.appendingPathComponent("mnt", isDirectory: true)
        guard Darwin.mkdir(mount.path, 0o700) == 0 else { throw UpdateError.install("Could not create a mount point") }
        let attach = Shell.run(Self.hdiutil, ["attach", "-readonly", "-nobrowse", "-noautoopen",
                                              "-mountpoint", mount.path, dmg.path],
                               environment: Self.toolEnvironment, timeout: config.toolTimeout)
        guard attach.ok else {
            Self.detach(mount, timeout: config.toolTimeout)   // in case it mounted before timing out
            throw UpdateError.badImage("The disk image could not be opened")
        }
        defer { Self.detach(mount, timeout: config.toolTimeout) }

        // 3. Exactly one app bundle.
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: mount.path)) ?? []
        let apps = names.filter { $0.hasSuffix(".app") && Self.isRealDirectory(mount.appendingPathComponent($0)) }
        guard apps.count == 1, let appName = apps.first else {
            throw UpdateError.badImage("The disk image does not hold exactly one app")
        }
        let mountedApp = mount.appendingPathComponent(appName, isDirectory: true)

        // 4. Identity and version.
        let executable = try checkBundle(mountedApp, expected: expected, current: current)

        // 5. Code signature intact.
        guard Shell.run(Self.codesign, ["--verify", "--deep", "--strict", mountedApp.path],
                        environment: Self.toolEnvironment, timeout: config.toolTimeout).ok else {
            throw UpdateError.badBundle("The app in the update failed its code-signature check")
        }

        // 6. Copy beside the installed app.
        let staged = stagingURL()
        guard !fm.fileExists(atPath: staged.path) else { throw UpdateError.install("A staging folder already exists") }
        do {
            guard Shell.run(Self.ditto, ["--noqtn", mountedApp.path, staged.path],
                            environment: Self.toolEnvironment, timeout: max(config.toolTimeout, 300)).ok else {
                throw UpdateError.install("Could not copy the update next to the installed app")
            }
            try Self.removeQuarantine(staged)
            guard Self.isRealDirectory(staged) else { throw UpdateError.install("The staged copy is missing") }
            // Re-read the copy: it, not the mounted image, is what gets installed.
            let stagedExecutable = try checkBundle(staged, expected: expected, current: current)
            guard stagedExecutable == executable else { throw UpdateError.badBundle("The staged copy differs from the image") }
            guard Shell.run(Self.codesign, ["--verify", "--deep", "--strict", staged.path],
                            environment: Self.toolEnvironment, timeout: config.toolTimeout).ok else {
                throw UpdateError.badBundle("The staged copy failed its code-signature check")
            }

            // 7. The new binary runs and reports the expected version.
            let binary = staged.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executable)
            guard Self.isRegularFile(binary) else { throw UpdateError.badBundle("The update has no executable") }
            var env = Self.toolEnvironment
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            let run = Shell.run(binary.path, ["--version"], environment: env, timeout: 20)
            let firstLine = run.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let reported = firstLine.split(separator: " ").last.map(String.init) ?? ""
            guard run.ok, reported == expected.text else {
                throw UpdateError.badBundle("The new version did not start correctly")
            }
        } catch {
            Self.removeTree(staged)
            throw error
        }
        return staged
    }

    /// Checks Info.plist; returns `CFBundleExecutable`.
    private func checkBundle(_ app: URL, expected: UpdateVersion, current: UpdateVersion) throws -> String {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = Self.readRegularFile(plistURL, maxBytes: 1024 * 1024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.badBundle("The update's app has no readable Info.plist")
        }
        guard (plist["CFBundleIdentifier"] as? String) == config.bundleID else {
            throw UpdateError.badBundle("The update is a different app")
        }
        guard let raw = plist["CFBundleShortVersionString"] as? String, let version = UpdateVersion(raw) else {
            throw UpdateError.badBundle("The update's app has no usable version")
        }
        guard version > current else { throw UpdateError.badBundle("The update's app is not newer than this copy") }
        guard version.text == expected.text else {
            throw UpdateError.badBundle("The update's app is version \(version), not \(expected)")
        }
        guard let exe = plist["CFBundleExecutable"] as? String, !exe.isEmpty, exe.count <= 255,
              !exe.contains("/"), exe != ".", exe != ".." else {
            throw UpdateError.badBundle("The update's app names no executable")
        }
        return exe
    }

    // MARK: swap

    /// True when the installed app's folder and the app itself are writable by us.
    public static func canReplace(_ installedApp: URL) -> Bool {
        let parent = installedApp.deletingLastPathComponent().path
        return isRealDirectory(installedApp) && access(parent, W_OK) == 0 && access(installedApp.path, W_OK) == 0
    }

    /// Put `staged` in place of the installed app; the old app is kept beside it
    /// as `.<App>.backup-<8 hex>.app` (removed by the new version at launch).
    /// On failure the installed app is restored and the staged copy removed.
    @discardableResult
    public func swap(staged: URL) throws -> URL {
        let installed = config.installedApp
        let backup = backupURL()
        let base = installed.deletingPathExtension().lastPathComponent
        // Only ever touch a folder named like our own staging copy, beside the app.
        guard Self.isStagingName(staged.lastPathComponent, appBase: base),
              staged.deletingLastPathComponent().standardizedFileURL.path
                == installed.deletingLastPathComponent().standardizedFileURL.path else {
            throw UpdateError.install("The staged update is not beside the installed app")
        }
        guard Self.isRealDirectory(installed), Self.isRealDirectory(staged) else {
            Self.removeTree(staged)
            throw UpdateError.install("The installed app could not be found")
        }
        var a = stat(), b = stat()
        guard lstat(installed.path, &a) == 0, lstat(staged.path, &b) == 0, a.st_dev == b.st_dev else {
            Self.removeTree(staged)
            throw UpdateError.install("The update was staged on a different disk")
        }

        // Atomic exchange where the volume supports it (APFS, HFS+): the
        // installed path never goes missing.
        if !config.forceTwoStepSwap {
            if renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 {
                // `staged` now holds the old app.
                if Darwin.rename(staged.path, backup.path) != 0 {
                    // Still matches the staging pattern, so the next launch removes it.
                    return staged
                }
                return backup
            }
            let swapErrno = errno
            guard swapErrno == ENOTSUP || swapErrno == EINVAL else {
                Self.removeTree(staged)
                throw UpdateError.install(Self.permissionWords(swapErrno))
            }
        }
        // Fallback: two renames with rollback.
        guard Darwin.rename(installed.path, backup.path) == 0 else {
            let e = errno
            Self.removeTree(staged)
            throw UpdateError.install(Self.permissionWords(e))
        }
        guard Darwin.rename(staged.path, installed.path) == 0 else {
            let e = errno
            _ = Darwin.rename(backup.path, installed.path)
            Self.removeTree(staged)
            throw UpdateError.install(Self.permissionWords(e))
        }
        return backup
    }

    /// Stage then swap; returns the backup. The work directory is the caller's.
    @discardableResult
    public func install(dmg: URL, signatureFile: Data, expectedVersion: String, workDirectory: URL) throws -> URL {
        let staged = try stage(dmg: dmg, signatureFile: signatureFile, expectedVersion: expectedVersion,
                               workDirectory: workDirectory)
        return try swap(staged: staged)
    }

    private static func permissionWords(_ e: Int32) -> String {
        e == EPERM || e == EACCES
            ? "macOS did not allow replacing the app; download the update from the release page"
            : "Could not replace the app (\(String(cString: strerror(e))))"
    }

    // MARK: names and cleanup

    func stagingURL() -> URL { siblingURL("update") }
    func backupURL() -> URL { siblingURL("backup") }

    private func siblingURL(_ kind: String) -> URL {
        let base = config.installedApp.deletingPathExtension().lastPathComponent
        return config.installedApp.deletingLastPathComponent()
            .appendingPathComponent(".\(base).\(kind)-\(Self.token()).app", isDirectory: true)
    }

    /// `.<appBase>.update-<8 lowercase hex>.app`
    public static func isStagingName(_ name: String, appBase: String) -> Bool { matches(name, appBase, "update") }
    /// `.<appBase>.backup-<8 lowercase hex>.app`
    public static func isBackupName(_ name: String, appBase: String) -> Bool { matches(name, appBase, "backup") }

    private static func matches(_ name: String, _ base: String, _ kind: String) -> Bool {
        let prefix = ".\(base).\(kind)-", suffix = ".app"
        guard !base.isEmpty, name.hasPrefix(prefix), name.hasSuffix(suffix),
              name.count == prefix.count + 8 + suffix.count else { return false }
        let token = name.dropFirst(prefix.count).dropLast(suffix.count)
        return token.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Remove our own staging and backup folders beside `installedApp` (exact
    /// names only, never through a symlink). Returns what was removed.
    @discardableResult
    public static func cleanupLeftovers(beside installedApp: URL) -> [URL] {
        let dir = installedApp.deletingLastPathComponent()
        let base = installedApp.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var removed: [URL] = []
        for name in names where isStagingName(name, appBase: base) || isBackupName(name, appBase: base) {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            guard isRealDirectory(url), url.standardizedFileURL.path != installedApp.standardizedFileURL.path else { continue }
            if removeTree(url) { removed.append(url) }
        }
        return removed
    }

    // MARK: helpers

    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// A regular file (no symlink) of at most `maxBytes`, read in one go.
    static func readRegularFile(_ url: URL, maxBytes: Int) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= off_t(maxBytes) else { return nil }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count == Int(st.st_size) else { return nil }
        return data
    }

    /// Strip `com.apple.quarantine` from every item (symlinks themselves, never their targets).
    static func removeQuarantine(_ root: URL) throws {
        var paths = [root.path]
        if let e = FileManager.default.enumerator(atPath: root.path) {
            while let rel = e.nextObject() as? String { paths.append((root.path as NSString).appendingPathComponent(rel)) }
        }
        for p in paths { _ = removexattr(p, quarantine, XATTR_NOFOLLOW) }
        for p in paths where getxattr(p, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            throw UpdateError.install("Could not clear the quarantine flag on the update")
        }
    }

    static func detach(_ mount: URL, timeout: TimeInterval) {
        guard isMounted(mount) else { return }
        if !Shell.run(hdiutil, ["detach", mount.path], environment: toolEnvironment, timeout: timeout).ok {
            _ = Shell.run(hdiutil, ["detach", "-force", mount.path], environment: toolEnvironment, timeout: timeout)
        }
    }

    /// True when `url` is the root of a mounted volume (its device differs from its parent's).
    static func isMounted(_ url: URL) -> Bool {
        var a = stat(), b = stat()
        guard lstat(url.path, &a) == 0, lstat(url.deletingLastPathComponent().path, &b) == 0 else { return false }
        return a.st_dev != b.st_dev
    }

    /// Remove a directory tree we created; refuses to descend into a mounted volume.
    @discardableResult
    static func removeTree(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return true }
        if (st.st_mode & S_IFMT) == S_IFDIR, let e = FileManager.default.enumerator(atPath: url.path) {
            while let rel = e.nextObject() as? String {
                if (e.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory,
                   isMounted(url.appendingPathComponent(rel)) { return false }
            }
        }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Remove a work directory, after making sure nothing is still mounted in it.
    public static func removeWorkDirectory(_ dir: URL, timeout: TimeInterval = 60) {
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        detach(mount, timeout: timeout)
        removeTree(dir)
    }
}
