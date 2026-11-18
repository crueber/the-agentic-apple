import Foundation

/// A small, append-only record of what the updater did, so a failed update or
/// relaunch leaves evidence: `~/Library/Logs/The Agentic Apple/update.log`.
/// Only versions, steps, PIDs and plain error text — never a key, token, URL
/// query or anything read from an agent. Rotated at 256 KB (one `.1` kept).
enum UpdateLog {
    static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "com.crueber.agentic-apple.update-log")

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(AppInfo.name)/update.log")
    }

    static func write(_ message: String) {
        let line = "\(stamp()) [\(AppInfo.version) pid \(getpid())] \(message)\n"
        queue.sync {
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f.string(from: Date())
    }
}
