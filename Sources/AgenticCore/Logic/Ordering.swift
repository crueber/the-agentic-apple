import Foundation

/// Agent order and show switches (README "Order, switches and dragging").
/// The saved order is a comma-separated id string ("grok,claude"); unknown and
/// duplicate ids are dropped, and agents missing from it follow in the default
/// order (OpenRouter → OpenCode → Grok → Codex → Claude). Visibility maps an id
/// to its show switch; a missing entry means shown.
///
/// Public API:
/// - `Ordering.parseOrder(_ value: String) -> [ProviderID]`
/// - `Ordering.serializeOrder(_ ids: [ProviderID]) -> String`
/// - `Ordering.visibleProviders(_ providers: [Provider], visibility: [ProviderID: Bool]) -> [Provider]`
///       available + shown, one per id, in default order
/// - `Ordering.orderedProviders(_ providers: [Provider], visibility: [ProviderID: Bool] = [:], order: String) -> [Provider]`
///       available agents, saved order first then the rest in default order (panel list: pass `[:]`)
/// - `Ordering.shownProviders(_ list: [Provider], visibility: [ProviderID: Bool]) -> [Provider]`
///       filter an ordered list by the switches, keeping its order (bar list)
/// - `Ordering.moveOrder(_ order: String, id: ProviderID, delta: Int) -> [ProviderID]`
///       swap with a neighbour inside the saved order (no-op at the edges / when id not saved)
/// - `Ordering.reorderInsert(_ order: String, visibleIDs: [ProviderID], id: ProviderID, insertIndex: Int) -> [ProviderID]`
///       full new order after dropping `id` at `insertIndex` among the visible rows;
///       hidden agents keep their place
/// - `Ordering.provider(_ providers: [Provider], id: ProviderID) -> Provider?`
public enum Ordering {
    public static func parseOrder(_ value: String) -> [ProviderID] {
        var out: [ProviderID] = []
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let raw = part.trimmingCharacters(in: .whitespaces)
            guard let id = ProviderID(rawValue: raw), !out.contains(id) else { continue }
            out.append(id)
        }
        return out
    }

    public static func serializeOrder(_ ids: [ProviderID]) -> String {
        ids.map(\.rawValue).joined(separator: ",")
    }

    public static func visibleProviders(_ providers: [Provider], visibility: [ProviderID: Bool] = [:]) -> [Provider] {
        var out: [Provider] = []
        for id in ProviderID.defaultOrder where visibility[id] != false {
            if let p = providers.first(where: { $0.id == id && $0.available }) { out.append(p) }
        }
        return out
    }

    public static func orderedProviders(_ providers: [Provider], visibility: [ProviderID: Bool] = [:],
                                        order: String) -> [Provider] {
        let visible = visibleProviders(providers, visibility: visibility)
        let saved = parseOrder(order)
        if saved.isEmpty { return visible }
        var out: [Provider] = []
        for id in saved {
            if let p = visible.first(where: { $0.id == id }) { out.append(p) }
        }
        for p in visible where !out.contains(where: { $0.id == p.id }) { out.append(p) }
        return out
    }

    public static func shownProviders(_ list: [Provider], visibility: [ProviderID: Bool]) -> [Provider] {
        list.filter { visibility[$0.id] != false }
    }

    public static func moveOrder(_ order: String, id: ProviderID, delta: Int) -> [ProviderID] {
        var ids = parseOrder(order)
        guard let index = ids.firstIndex(of: id) else { return ids }
        let target = index + delta
        guard target >= 0, target < ids.count else { return ids }
        ids.swapAt(index, target)
        return ids
    }

    public static func reorderInsert(_ order: String, visibleIDs: [ProviderID], id: ProviderID,
                                     insertIndex: Int) -> [ProviderID] {
        var ids = parseOrder(order)
        if ids.isEmpty { ids = ProviderID.defaultOrder }
        for p in ProviderID.defaultOrder where !ids.contains(p) { ids.append(p) }
        guard let from = visibleIDs.firstIndex(of: id) else { return ids }
        var without = visibleIDs
        without.remove(at: from)
        let to = min(without.count, max(0, insertIndex))
        if to == from { return ids }
        guard let at = ids.firstIndex(of: id) else { return ids }
        ids.remove(at: at)
        if to >= without.count {
            let anchor = ids.firstIndex(of: without[without.count - 1]) ?? (ids.count - 1)
            ids.insert(id, at: anchor + 1)
        } else {
            ids.insert(id, at: ids.firstIndex(of: without[to]) ?? ids.count)
        }
        return ids
    }

    public static func provider(_ providers: [Provider], id: ProviderID) -> Provider? {
        providers.first { $0.id == id }
    }
}
