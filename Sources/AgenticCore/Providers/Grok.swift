import Foundation

/// Grok collector, ported from the reference plugin's `grok.js` + `collectGrok`.
///
/// Grok's TUI logs the billing snapshot it fetched when a session starts as
/// `billing: fetched credits config` in `~/.grok/logs/unified.jsonl`. That line
/// carries the plan pool's usage percentage, its period and the tier. Reading it
/// needs no token, no network and no Grok process of our own.
///
/// Local session ledgers (`sessions/<workspace>/<session>/usage.json`) give
/// per-turn token counts for this period's activity. Only numbers are read;
/// prompts, responses and `auth.json` are never opened.
///
/// Grok Bot keeps a separate weekly allowance; its desktop app caches the
/// reading as small JSON `*.blob` files under its persistence directory.
public struct GrokCollector: ProviderCollector {
    public init() {}
    public var id: ProviderID { .grok }

    static let dayMs: Double = 86_400_000
    static let maxLogScan = 32 * 1024 * 1024
    static let chunk = 256 * 1024
    static let billingMarker = "billing: fetched credits config"

    public func collect(_ context: CollectorContext) async -> Provider {
        Self.collectSync(context)
    }

    // MARK: - Paths

    static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    /// grokHome override, else $GROK_HOME, else ~/.grok.
    static func grokHome(_ context: CollectorContext) -> URL {
        let explicit = context.grokHome.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return expand(explicit, home: context.home) }
        if let env = context.environment["GROK_HOME"], !env.isEmpty { return expand(env, home: context.home) }
        return context.home.appendingPathComponent(".grok")
    }

    /// Grok Bot persistence directories, in the order they are tried.
    static func botHomes(_ context: CollectorContext) -> [URL] {
        let explicit = context.botHome.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return [expand(explicit, home: context.home)] }
        if let env = context.environment["GROK_BOT_HOME"], !env.isEmpty { return [expand(env, home: context.home)] }
        let config: URL
        if let xdg = context.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            config = expand(xdg, home: context.home)
        } else {
            config = context.home.appendingPathComponent(".config")
        }
        return [
            context.home.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence"),
            config.appendingPathComponent("Grok Bot/sand-client-persistence"),
        ]
    }

    // MARK: - Snapshot

    /// Scan the log backwards in chunks and return the last billing snapshot.
    /// Works on bytes so a chunk boundary can never split a UTF-8 character.
    static func lastBillingMessage(_ logURL: URL) -> (message: [String: Any]?, error: String) {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return (nil, "no Grok log at \(logURL.path)")
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return (nil, "could not read the Grok log") }

        let marker = Data(billingMarker.utf8)
        var end = size
        var carry = Data()
        var scanned = 0
        while end > 0 && scanned < maxLogScan {
            let start = end > UInt64(chunk) ? end - UInt64(chunk) : 0
            let length = Int(end - start)
            guard (try? handle.seek(toOffset: start)) != nil,
                  let read = try? handle.read(upToCount: length) else { break }
            var buffer = read
            buffer.append(carry)
            var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            if start > 0, !lines.isEmpty {
                carry = Data(lines.removeFirst())
            } else {
                carry = Data()
            }
            for line in lines.reversed() {
                guard line.range(of: marker) != nil else { continue }
                // A torn write can leave a partial line; keep looking backwards.
                if let row = Sanitize.jsonObject(Data(line)), (row["msg"] as? String) == billingMarker {
                    return (row, "")
                }
            }
            scanned += length
            end = start
        }
        return (nil, "no billing snapshot in the Grok log yet")
    }

    struct Snapshot {
        var tier: String
        var snapshotAt: Double
        var usedPercent: Double
        var periodType: String
        var periodStart: Double
        var resetsAt: Double
        var expired: Bool
    }

    static func parseConfig(_ message: [String: Any], nowMs: Double) -> Snapshot? {
        guard let ctx = message["ctx"] as? [String: Any],
              let config = ctx["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any] else { return nil }
        // The server omits creditUsagePercent at the start of a fresh period;
        // the TUI renders that as 0%, so absent means zero.
        let used = Sanitize.number(config["creditUsagePercent"]) ?? 0
        let endMs = Sanitize.dateMs(period["end"])
        guard endMs > 0 else { return nil }
        return Snapshot(
            tier: Sanitize.plain(ctx["subscriptionTier"], max: 60),
            snapshotAt: max(0, Sanitize.dateMs(message["ts"])),
            usedPercent: Sanitize.clamp(used, 0, 100),
            periodType: Sanitize.text(period["type"], max: 60),
            periodStart: Sanitize.dateMs(period["start"]),
            resetsAt: endMs,
            expired: nowMs >= endMs)
    }

    /// The panel title and bar label for the plan pool's period.
    static func period(_ periodType: String) -> (short: String, detail: String) {
        let value = periodType.uppercased()
        if value.contains("MONTH") { return ("mo", "Monthly limit") }
        if value.contains("DAY") { return ("day", "Daily limit") }
        return ("wk", "Weekly limit")
    }

    // MARK: - Grok Bot

    struct BotReading {
        var percent: Double
        var resetsAt: Double
        var readAt: Double
        var expiresAt: Double
        var plan: String
    }

    /// The newest small JSON blob carrying percentUsed/nextResetMs. Never touches
    /// the browser session or any token.
    static func readBotUsage(_ root: URL) -> BotReading? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        var best: BotReading?
        for name in names where name.hasSuffix(".blob") {
            let file = root.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.intValue <= 65_536,
                  let doc = Sanitize.readJSONFile(file, maxBytes: 65_536),
                  let value = doc["value"] as? [String: Any],
                  let reading = value["reading"] as? [String: Any],
                  let usage = reading["usage"] as? [String: Any],
                  let pct = Sanitize.number(usage["percentUsed"]),
                  let reset = Sanitize.number(usage["nextResetMs"]) else { continue }
            let mtime = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
            let readAt = Sanitize.number(reading["readAtMs"]).flatMap { $0 != 0 ? $0 : nil } ?? mtime
            guard readAt != 0 else { continue }
            let candidate = BotReading(percent: Sanitize.clamp(pct, 0, 100), resetsAt: reset, readAt: readAt,
                                       expiresAt: Sanitize.number(value["expiresAtMs"]) ?? 0,
                                       plan: Sanitize.plain(usage["grokPlanLabel"], max: 60))
            if best == nil || candidate.readAt > best!.readAt { best = candidate }
        }
        return best
    }

    // MARK: - Local session ledgers

    struct LocalTotals {
        var sessions = 0
        var turns = 0.0
        var tokens = 0.0
    }

    static func walkSessionUsage(_ root: URL, sinceMs: Double) -> LocalTotals? {
        let fm = FileManager.default
        guard let workspaces = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        var totals = LocalTotals()
        let cutoff = sinceMs - dayMs
        func isDir(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        func endedMs(_ value: Any?) -> Double? {
            guard let s = value as? String, !s.isEmpty else { return nil }
            let ms = Sanitize.isoDateMs(s)
            return ms > 0 ? ms : nil
        }
        for workspace in workspaces where isDir(workspace) {
            guard let sessions = try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for session in sessions where isDir(session) {
                let usageURL = session.appendingPathComponent("usage.json")
                guard let attrs = try? fm.attributesOfItem(atPath: usageURL.path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime.timeIntervalSince1970 * 1000 >= cutoff,
                      let doc = Sanitize.readJSONFile(usageURL) else { continue }

                var matched = false
                var countedTurn = false
                for case let turn as [String: Any] in (doc["turns"] as? [Any]) ?? [] {
                    if let ended = endedMs(turn["endedAt"]), ended < sinceMs { continue }
                    matched = true
                    countedTurn = true
                    totals.turns += max(1, Sanitize.number(turn["turnCount"]) ?? 1)
                    totals.tokens += max(0, Sanitize.number(turn["totalTokens"]) ?? 0)
                }
                if !countedTurn {
                    // Older ledgers have no turns array: use the session total only
                    // when the session itself was updated inside the period.
                    guard let updated = endedMs(doc["updatedAt"]), updated >= sinceMs,
                          let usage = doc["session"] as? [String: Any] else { continue }
                    matched = true
                    totals.turns += max(0, Sanitize.number(usage["turnCount"]) ?? 0)
                    totals.tokens += max(0, Sanitize.number(usage["totalTokens"]) ?? 0)
                }
                if matched { totals.sessions += 1 }
            }
        }
        return totals
    }

    // MARK: - Collect

    static func collectSync(_ context: CollectorContext) -> Provider {
        var provider = Provider(id: .grok, source: "grok-log")
        let nowMs = context.nowMs
        let home = grokHome(context)
        let logURL = home.appendingPathComponent("logs/unified.jsonl")
        let found = lastBillingMessage(logURL)

        // Grok Bot (the desktop app) keeps its own weekly allowance, read from its
        // cache. It is read first: someone who only uses Grok Bot has no CLI log.
        var bot: BotReading?
        for root in botHomes(context) {
            if let reading = readBotUsage(root) { bot = reading; break }
        }

        guard let message = found.message, let snapshot = parseConfig(message, nowMs: nowMs) else {
            // No CLI snapshot, but Grok Bot has a reading: Grok still shows both
            // meters — the plan's weekly window (empty: no CLI reading to fill it)
            // and the Grok Bot allowance.
            if let bot {
                provider.source = "grok-bot"
                provider.tier = bot.plan
                provider.readAt = bot.readAt
                provider.limits.append(Limit(key: "weekly", label: "Weekly limit", short: "wk", percent: 0))
                provider.limits.append(botLimit(bot, nowMs: nowMs))
                provider.available = true
                return provider
            }
            // Grok not installed: nothing to say. Installed but no snapshot yet:
            // say how to create one (the bar skips an unavailable agent anyway).
            if FileManager.default.fileExists(atPath: home.path) {
                provider.error = found.message == nil
                    ? Sanitize.plain(found.error, max: 300)
                    : "the latest billing line has no recognizable config"
                provider.hint = "Run `grok` once (and open /usage) to create the first usage snapshot."
            }
            return provider
        }

        provider.tier = snapshot.tier
        provider.readAt = snapshot.snapshotAt
        let period = period(snapshot.periodType)
        provider.limits.append(Limit(key: "weekly", label: period.detail, short: period.short,
                                     percent: snapshot.usedPercent, resetsAt: snapshot.resetsAt,
                                     stale: snapshot.expired))

        if let bot {
            provider.limits.append(botLimit(bot, nowMs: nowMs))
        }

        let since = snapshot.periodStart > 0 ? snapshot.periodStart : nowMs - 7 * dayMs
        if let local = walkSessionUsage(home.appendingPathComponent("sessions"), sinceMs: since) {
            provider.activity = Activity(period: "week", prompts: Int(min(local.turns, 1e9).rounded()),
                                         tokens: Int(min(local.tokens, Double(Int.max / 2)).rounded()))
        }
        provider.available = !provider.limits.isEmpty || !provider.tier.isEmpty
        return provider
    }

    /// The Grok Bot weekly window; stale once past the cache's expiry or its reset.
    static func botLimit(_ bot: BotReading, nowMs: Double) -> Limit {
        let expired = bot.expiresAt > 0 && nowMs > bot.expiresAt
        let elapsed = bot.resetsAt > 0 && nowMs >= bot.resetsAt
        return Limit(key: "bot", label: "Grok Bot weekly", short: "bot",
                     percent: bot.percent, resetsAt: Sanitize.dateMs(bot.resetsAt),
                     stale: expired || elapsed)
    }
}
