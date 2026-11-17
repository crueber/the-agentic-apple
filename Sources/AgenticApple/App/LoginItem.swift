import Foundation
import ServiceManagement

/// Launch at login through SMAppService (macOS 13+). Only an installed copy
/// (in /Applications or ~/Applications) manages it: `swift run` has no bundle,
/// and a copy run from the disk image, a translocated path or `dist/` would
/// register a path that is gone after a restart — and must not record the
/// user's preference either.
enum LoginItem {
    static var isAvailable: Bool { AppInfo.isBundled && isInstalledCopy }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("The Agentic Apple: launch at login change failed: \(error.localizedDescription)")
        }
        return isEnabled
    }

    /// Unregisters regardless of the current status (uninstall). True when nothing is left registered.
    static func unregister() -> Bool {
        guard AppInfo.isBundled else { return false }
        if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound { return true }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            FileHandle.standardError.write(Data("Could not remove the login item: \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// Where the running bundle lives. Login items registered from a mounted
    /// disk image, a translocated copy or `dist/` would point at a path that
    /// is gone after a restart, so only an installed copy registers itself.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Called at every launch so the app comes back after a restart:
    /// - first launch of an installed copy: turn launch at login on (the
    ///   user can switch it off; that choice is remembered);
    /// - the user wants it on but macOS lost the registration (the app was
    ///   reinstalled or moved): register again.
    /// A login item the user disabled in System Settings reports
    /// `.requiresApproval` and is left alone.
    static func ensureOnLaunch(defaults: UserDefaults, key: String) {
        guard isAvailable else { return }
        let wanted = defaults.object(forKey: key) as? Bool
        let status = SMAppService.mainApp.status
        switch (wanted, status) {
        case (nil, .notRegistered), (nil, .notFound), (true, .notRegistered), (true, .notFound):
            set(true)
        default:
            break
        }
        if wanted == nil { defaults.set(isEnabled, forKey: key) }
    }

    static var needsApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }
}
