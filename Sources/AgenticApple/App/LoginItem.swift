import Foundation
import ServiceManagement

/// Launch at login through SMAppService (macOS 13+). Only meaningful for the
/// bundled app; `swift run` has no bundle to register.
enum LoginItem {
    static var isAvailable: Bool { AppInfo.isBundled }

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
        guard isAvailable else { return false }
        if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound { return true }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            FileHandle.standardError.write(Data("Could not remove the login item: \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    static var needsApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }
}
