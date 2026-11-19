import Foundation
import AgenticCore

enum BarStyle: String, CaseIterable, Identifiable {
    case bars, text, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: return "Meters"
        case .text: return "Percentages"
        case .icon: return "Marks only"
        }
    }
}

/// Settings in UserDefaults, under the reference plugin's keys
/// (`barStyle`, `show<Agent>`, `providerOrder`, `refreshIntervalSec`, …).
/// Every property writes through on change.
@MainActor
final class AppSettings: ObservableObject {
    let defaults: UserDefaults

    @Published var barStyle: BarStyle { didSet { defaults.set(barStyle.rawValue, forKey: Keys.barStyle) } }
    @Published var visibility: [ProviderID: Bool] {
        didSet { for id in ProviderID.allCases { defaults.set(visibility[id] != false, forKey: Self.showKey(id)) } }
    }
    @Published var providerOrder: String { didSet { defaults.set(providerOrder, forKey: Keys.providerOrder) } }
    @Published var refreshIntervalSec: Int {
        didSet {
            let clamped = Schedule.clampInt(Double(refreshIntervalSec), 60, 3600, fallback: 300)
            if clamped != refreshIntervalSec { refreshIntervalSec = clamped; return }
            defaults.set(refreshIntervalSec, forKey: Keys.refreshIntervalSec)
        }
    }
    @Published var warnPercent: Int {
        didSet { defaults.set(Schedule.clampInt(Double(warnPercent), 0, 100, fallback: 70), forKey: Keys.warnPercent) }
    }
    @Published var criticalPercent: Int {
        didSet { defaults.set(Schedule.clampInt(Double(criticalPercent), 0, 100, fallback: 90), forKey: Keys.criticalPercent) }
    }
    /// "#rrggbb" or "" (system default).
    @Published var warningColor: String { didSet { defaults.set(warningColor, forKey: Keys.warningColor) } }
    @Published var criticalColor: String { didSet { defaults.set(criticalColor, forKey: Keys.criticalColor) } }
    @Published var opencodeCommand: String { didSet { defaults.set(opencodeCommand, forKey: Keys.opencodeCommand) } }
    @Published var codexCommand: String { didSet { defaults.set(codexCommand, forKey: Keys.codexCommand) } }
    @Published var grokHome: String { didSet { defaults.set(grokHome, forKey: Keys.grokHome) } }
    @Published var botHome: String { didSet { defaults.set(botHome, forKey: Keys.botHome) } }
    @Published var authFile: String { didSet { defaults.set(authFile, forKey: Keys.authFile) } }
    @Published var showActivity: Bool { didSet { defaults.set(showActivity, forKey: Keys.showActivity) } }
    /// Mirrors SMAppService's state; the source of truth is the system.
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }
    /// OpenRouter with a management key: how many of the keys used most this month
    /// the panel lists (0–12, default 3). The bar never shows key rows.
    /// OpenRouter with a management key: the usage meter compares this month with
    /// the average of the last N full months (1–12, default 2). 0 = the meter is
    /// off (and no analytics request is made). The single source of truth: the
    /// Settings toggle is `openrouterAverageMonths > 0`.
    @Published var openrouterAverageMonths: Int {
        didSet {
            let clamped = Self.clampAverageMonths(openrouterAverageMonths)
            if clamped != openrouterAverageMonths { openrouterAverageMonths = clamped; return }
            defaults.set(openrouterAverageMonths, forKey: Keys.openrouterAverageMonths)
        }
    }
    @Published var openrouterKeyRows: Int {
        didSet {
            let clamped = Self.clampKeyRows(openrouterKeyRows)
            if clamped != openrouterKeyRows { openrouterKeyRows = clamped; return }
            defaults.set(openrouterKeyRows, forKey: Keys.openrouterKeyRows)
        }
    }
    /// Check for and install signed updates automatically (default on).
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: Keys.autoUpdate) } }

    enum Keys {
        static let barStyle = "barStyle"
        static let providerOrder = "providerOrder"
        static let refreshIntervalSec = "refreshIntervalSec"
        static let warnPercent = "warnPercent"
        static let criticalPercent = "criticalPercent"
        static let warningColor = "warningColor"
        static let criticalColor = "criticalColor"
        static let opencodeCommand = "opencodeCommand"
        static let codexCommand = "codexCommand"
        static let grokHome = "grokHome"
        static let botHome = "botHome"
        static let authFile = "authFile"
        static let showActivity = "showActivity"
        static let launchAtLogin = "launchAtLogin"
        static let autoUpdate = "autoUpdate"
        static let openrouterKeyRows = "openrouterKeyRows"
        static let openrouterAverageMonths = "openrouterAverageMonths"
    }

    nonisolated static let defaultKeyRows = 3
    nonisolated static func clampKeyRows(_ n: Int) -> Int { min(12, max(0, n)) }
    nonisolated static let defaultAverageMonths = 2
    nonisolated static func clampAverageMonths(_ n: Int) -> Int { min(12, max(0, n)) }

    /// "show" + capitalised id, exactly as the reference: showOpenrouter, showOpencode, …
    nonisolated static func showKey(_ id: ProviderID) -> String {
        "show" + id.rawValue.prefix(1).uppercased() + id.rawValue.dropFirst()
    }

    init(defaults: UserDefaults = AppInfo.defaults) {
        self.defaults = defaults
        let s = SettingsSnapshot.read(defaults)
        barStyle = s.barStyle
        visibility = s.visibility
        providerOrder = s.providerOrder
        refreshIntervalSec = s.refreshIntervalSec
        warnPercent = s.warnPercent
        criticalPercent = s.criticalPercent
        warningColor = defaults.string(forKey: Keys.warningColor) ?? ""
        criticalColor = defaults.string(forKey: Keys.criticalColor) ?? ""
        opencodeCommand = s.opencodeCommand
        codexCommand = s.codexCommand
        grokHome = s.grokHome
        botHome = s.botHome
        authFile = s.authFile
        showActivity = defaults.object(forKey: Keys.showActivity) as? Bool ?? true
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        openrouterKeyRows = s.openrouterKeyRows
        openrouterAverageMonths = s.openrouterAverageMonths
    }

    func isShown(_ id: ProviderID) -> Bool { visibility[id] != false }

    func setShown(_ id: ProviderID, _ shown: Bool) {
        var next = visibility
        next[id] = shown
        visibility = next
    }

    var snapshot: SettingsSnapshot { SettingsSnapshot.read(defaults) }
}

/// A plain, non-isolated read of the settings (CLI and collector context).
struct SettingsSnapshot: Sendable {
    var barStyle: BarStyle = .bars
    var visibility: [ProviderID: Bool] = [:]
    var providerOrder = ""
    var refreshIntervalSec = 300
    var warnPercent = 70
    var criticalPercent = 90
    var opencodeCommand = ""
    var codexCommand = ""
    var grokHome = ""
    var botHome = ""
    var authFile = ""
    var openrouterKeyRows = 3
    var openrouterAverageMonths = 2

    static func read(_ d: UserDefaults) -> SettingsSnapshot {
        typealias K = AppSettings.Keys
        var s = SettingsSnapshot()
        s.barStyle = BarStyle(rawValue: d.string(forKey: K.barStyle) ?? "") ?? .bars
        for id in ProviderID.allCases {
            s.visibility[id] = d.object(forKey: AppSettings.showKey(id)) as? Bool ?? true
        }
        s.providerOrder = d.string(forKey: K.providerOrder) ?? ""
        s.refreshIntervalSec = Schedule.clampInt((d.object(forKey: K.refreshIntervalSec) as? NSNumber)?.doubleValue, 60, 3600, fallback: 300)
        s.warnPercent = Schedule.clampInt((d.object(forKey: K.warnPercent) as? NSNumber)?.doubleValue, 0, 100, fallback: 70)
        s.criticalPercent = Schedule.clampInt((d.object(forKey: K.criticalPercent) as? NSNumber)?.doubleValue, 0, 100, fallback: 90)
        s.opencodeCommand = d.string(forKey: K.opencodeCommand) ?? ""
        s.codexCommand = d.string(forKey: K.codexCommand) ?? ""
        s.grokHome = d.string(forKey: K.grokHome) ?? ""
        s.botHome = d.string(forKey: K.botHome) ?? ""
        s.authFile = d.string(forKey: K.authFile) ?? ""
        s.openrouterKeyRows = AppSettings.clampKeyRows(
            Schedule.clampInt((d.object(forKey: K.openrouterKeyRows) as? NSNumber)?.doubleValue, 0, 12,
                              fallback: AppSettings.defaultKeyRows))
        s.openrouterAverageMonths = AppSettings.clampAverageMonths(
            Schedule.clampInt((d.object(forKey: K.openrouterAverageMonths) as? NSNumber)?.doubleValue, 0, 12,
                              fallback: AppSettings.defaultAverageMonths))
        return s
    }

    func context(searchPath: [String], now: Date = Date()) -> CollectorContext {
        var context = CollectorContext(searchPath: searchPath,
                                       opencodeCommand: opencodeCommand, codexCommand: codexCommand,
                                       grokHome: grokHome, botHome: botHome, authFile: authFile, now: now)
        context.openrouterAverageMonths = openrouterAverageMonths
        return context
    }
}
