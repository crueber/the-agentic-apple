import Foundation
import AgenticCore

/// Everything the bar and the panel draw, as a plain value. The live app builds
/// it from the Store; `--render-preview` builds it from a fixture with a fixed
/// clock, so both paths use the same views.
struct DisplayState: Equatable {
    var providers: [Provider] = []
    var history: CycleHistory = .empty
    var order: String = ""
    var visibility: [ProviderID: Bool] = [:]
    var warn: Double = 70
    var critical: Double = 90
    var showActivity = true
    /// OpenRouter account-wide: key rows listed in the panel (`openrouterKeyRows`).
    var openrouterKeyRows = 3
    var barStyle: BarStyle = .bars
    var palette = Palette()
    /// Epoch ms used for every relative time.
    var now: Double = Date().timeIntervalSince1970 * 1000
    var lastFetchMs: Double = 0
    var lastError: String = ""
    /// "Updated to 0.2.1", shown once after a self-update.
    var updateNote: String = ""
    var busy = false
    /// Manual refresh is in its 30 s cooldown window after a recent manual click.
    var refreshCoolingDown = false
    /// No fetch has finished yet in this session and nothing was cached.
    var looking = false

    /// Every available agent, saved order first.
    var availableProviders: [Provider] { Ordering.orderedProviders(providers, visibility: [:], order: order) }
    /// Bar list: available agents filtered by the show switches.
    var barProviders: [Provider] { Ordering.shownProviders(availableProviders, visibility: visibility) }
    /// Panel list: shown agents only; deselected agents are managed in Settings → Agents.
    var panelProviders: [Provider] { barProviders }
    var hiddenCount: Int { availableProviders.count - barProviders.count }

    func isShown(_ id: ProviderID) -> Bool { visibility[id] != false }

    func windows(_ p: Provider) -> [MeterWindow] {
        Meters.windowsFor(p, history: history, warn: warn, critical: critical, keyRows: openrouterKeyRows)
    }

    var heroPercent: String {
        Summary.heroPercentText(barProviders, history: history, warn: warn, critical: critical)
    }

    var heroPercentState: MeterState {
        guard let top = Meters.highestMeterPercent(barProviders, history: history, warn: warn, critical: critical) else { return .normal }
        return Meters.stateOf(top, warn: warn, critical: critical)
    }

    var heroMeta: String {
        var parts: [String] = []
        let n = availableProviders.count
        if n > 0 { parts.append("\(n) " + (n == 1 ? "agent" : "agents")) }
        if hiddenCount > 0 { parts.append("\(hiddenCount) hidden") }
        let ago = Format.updatedAgo(lastFetchMs, now: now)
        if !ago.isEmpty { parts.append(ago) }
        if !lastError.isEmpty { parts.append("read failed") }
        if parts.isEmpty { parts.append(busy ? "Looking for agents…" : "No agents yet") }
        return parts.joined(separator: " · ")
    }

    var footerText: String {
        var parts: [String] = []
        if !updateNote.isEmpty { parts.append(updateNote) }
        let updated = Format.updatedText(lastFetchMs, now: now)
        if !updated.isEmpty { parts.append(updated) }
        if !lastError.isEmpty { parts.append(lastError) }
        parts.append("local agent records")
        return parts.joined(separator: " · ")
    }

    var tooltip: String {
        if !barProviders.isEmpty {
            return Summary.tooltip(barProviders, history: history, now: now, warn: warn, critical: critical)
        }
        return availableProviders.isEmpty ? Summary.noAgents : Summary.allHiddenTooltip
    }

    /// One line per shown agent ("Claude: 5h 18% · 7d 62%"), as the reference's `text` IPC.
    var textLines: [String] {
        barProviders.map { $0.name + ": " + Summary.compactText($0, history: history, warn: warn, critical: critical) }
    }

    var isAlarming: Bool {
        barProviders.contains { Meters.isAlarming($0, history: history, warn: warn, critical: critical) }
    }
}
