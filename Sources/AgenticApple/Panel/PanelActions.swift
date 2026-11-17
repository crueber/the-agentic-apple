import Foundation
import AgenticCore

/// What the panel can ask of the app. The preview passes no-ops.
struct PanelActions {
    var refresh: () -> Void = {}
    var setShown: (ProviderID, Bool) -> Void = { _, _ in }
    /// Drop `id` at `insertIndex` among the panel rows (without the dragged row).
    var reorder: (ProviderID, Int) -> Void = { _, _ in }
    var openSettings: () -> Void = {}
}
