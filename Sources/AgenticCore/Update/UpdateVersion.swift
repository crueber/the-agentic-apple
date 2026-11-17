import Foundation

/// A release version: one to four dot-separated decimal components
/// ("0.2.1", "v1.0"), compared numerically with missing components as zero.
/// Anything else — pre-release suffixes, build metadata, letters, empty parts,
/// leading "+"/"-", absurdly long numbers — is not a version, so it can never
/// count as newer and never reaches an asset name.
public struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    /// The canonical text, without a "v" prefix ("0.2.1").
    public let text: String

    public init?(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        guard !s.isEmpty, s.count <= 32 else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var comps: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(p) else { return nil }
            comps.append(n)
        }
        components = comps
        text = parts.joined(separator: ".")
    }

    public var description: String { text }

    public static func < (a: UpdateVersion, b: UpdateVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: UpdateVersion, b: UpdateVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var c = components
        while c.count > 1, c.last == 0 { c.removeLast() }
        hasher.combine(c)
    }

    /// True when `candidate` parses and is strictly newer than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = UpdateVersion(candidate), let b = UpdateVersion(current) else { return false }
        return a > b
    }
}
