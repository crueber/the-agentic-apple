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

    static var needsApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }
}
