import Foundation

/// Untrusted values from files, commands and the network go through these.
public enum Sanitize {
    /// A finite number from any JSON-ish value, or nil.
    public static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int: return Double(n)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            guard let d = Double(t), d.isFinite else { return nil }
            return d
        default: return nil
        }
    }

    public static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }

    /// A bounded string; non-strings become "".
    public static func text(_ value: Any?, max: Int = 200) -> String {
        guard let s = value as? String else { return "" }
        return String(s.prefix(max))
    }

    /// Display-safe text: bounded, control characters removed, angle brackets neutralised.
    public static func plain(_ value: Any?, max: Int = 200) -> String {
        let s = text(value, max: max)
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if scalar == "<" { out.append("\u{2039}") }
            else if scalar == ">" { out.append("\u{203A}") }
            else if CharacterSet.controlCharacters.contains(scalar) { out.append(" ") }
            else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    /// Epoch milliseconds from seconds, milliseconds or an ISO-8601 string. 0 when unknown.
    public static func dateMs(_ value: Any?) -> Double {
        if let n = number(value), n > 0 {
            return n <= 1e12 ? (n * 1000).rounded() : n.rounded()
        }
        guard let s = value as? String, !s.isEmpty else { return 0 }
        return isoDateMs(s)
    }

    public static func isoDateMs(_ s: String) -> Double {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        // Tolerate microsecond fractions ("2026-11-17T10:00:00.123456+00:00").
        if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let trimmed = String(s[..<dot]) + String(s[tz...])
            if let d = f2.date(from: trimmed) { return d.timeIntervalSince1970 * 1000 }
        }
        return 0
    }

    /// Parse JSON data into a dictionary, or nil.
    public static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Read a JSON file into a dictionary (bounded to 8 MB), or nil.
    public static func readJSONFile(_ url: URL, maxBytes: Int = 8 * 1024 * 1024) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return jsonObject(data)
    }

    /// Replace anything token-shaped with "…": `Bearer …`, `sk-…`, JWTs
    /// (`eyJ…`), and long base64/hex-like runs that mix letters and digits.
    /// For text that is shown but came from a process we don't control.
    public static func redactSecrets(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"(?i)\b(bearer)(\s*[:=]?\s+)[^\s"',;]+"#, "$1$2…"),
            (#"\beyJ[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)*"#, "…"),
            (#"\b(sk|pk|rk)-[A-Za-z0-9_\-]{6,}"#, "$1-…"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)(["']?\s*[:=]\s*["']?)[^\s"',;]+"#, "$1$2…"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Long runs of token alphabet that contain both a letter and a digit
        // (judged per path component, so ordinary paths survive).
        guard let run = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/=_\-]{24,}"#) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in run.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            let chunks = piece.split(separator: "/")
            let tokenLike = chunks.contains { chunk in
                chunk.count >= 24 && chunk.contains(where: \.isNumber) && chunk.contains(where: \.isLetter)
            }
            guard tokenLike else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + "…"
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
