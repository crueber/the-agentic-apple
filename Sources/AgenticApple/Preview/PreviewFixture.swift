import Foundation
import AgenticCore

/// Invented data mirroring the reference plugin's preview.png. No real key,
/// account, workspace, spend, credits or usage figure appears here.
enum PreviewFixture {
    /// A fixed clock so every "Resets in …" is deterministic: 2026-11-16 10:00 UTC.
    static let now: Double = 1_794_823_200_000
    static let minute: Double = 60_000
    static let hour: Double = 3_600_000
    static let day: Double = 86_400_000

    static var providers: [Provider] {
        var openrouter = Provider(id: .openrouter, available: true, tier: "key …demo", status: "Key limit",
                                  source: "fixture",
                                  activity: Activity(period: "today", prompts: 1, tokens: 84_000),
                                  money: Money(label: "key …demo", limit: 20, spend: 12.40, credits: 35,
                                               totalCredits: 50, resetInterval: "monthly", resetsAt: now + 21 * day),
                                  readAt: now)
        openrouter.name = "OpenRouter"

        let opencode = Provider(id: .opencode, available: true, tier: "demo", status: "Go", source: "fixture",
                                limits: [
                                    Limit(key: "session", label: "5-hour session", short: "5h", percent: 24,
                                          resetsAt: now + 4 * hour + 48 * minute),
                                    Limit(key: "weekly", label: "Weekly (7-day)", short: "7d", percent: 41, resetsAt: now + 4 * day),
                                    Limit(key: "monthly", label: "Monthly", short: "1m", percent: 9, resetsAt: now + 18 * day),
                                ],
                                activity: Activity(period: "today", prompts: 4, tokens: 320_000),
                                budgets: [Budget(label: "Console", spend: 2.50, limit: 10, percent: 25)],
                                readAt: now)

        let grok = Provider(id: .grok, available: true, tier: "SuperGrok", source: "fixture",
                            limits: [
                                Limit(key: "weekly", label: "Weekly limit", short: "7d", percent: 41, resetsAt: now + 4 * day),
                                Limit(key: "bot", label: "Grok Bot weekly", short: "bot", percent: 42.7, resetsAt: now + 3 * day),
                            ],
                            activity: Activity(period: "week", prompts: 2, tokens: 1_200_000),
                            readAt: now)

        let codex = Provider(id: .codex, available: true, tier: "Plus", source: "fixture",
                             limits: [
                                Limit(key: "session", label: "Session (5-hour)", short: "5h", percent: 12,
                                      resetsAt: now + 7 * hour + 12 * minute),
                                Limit(key: "weekly", label: "Weekly (7-day)", short: "7d", percent: 34, resetsAt: now + 5 * day),
                                Limit(key: "review", label: "Code review", short: "rev", percent: 5, resetsAt: now + 5 * day),
                             ],
                             activity: Activity(period: "today", prompts: 2, tokens: 180_000),
                             readAt: now)

        let claude = Provider(id: .claude, available: true, tier: "Max 5x", source: "fixture",
                              limits: [
                                Limit(key: "session", label: "Session (5-hour)", short: "5h", percent: 18, resetsAt: now + 6 * hour),
                                Limit(key: "weekly", label: "Weekly (7-day)", short: "7d", percent: 62, resetsAt: now + 5 * day),
                                Limit(key: "fable", label: "Fable Weekly", short: "fable", percent: 7, resetsAt: now + 5 * day),
                              ],
                              activity: Activity(period: "today", prompts: 3, tokens: 210_000),
                              readAt: now)

        let antigravity = Provider(id: .antigravity, available: true, tier: "Google AI Pro", source: "fixture",
                                   limits: [
                                    Limit(key: "session", label: "Session (5-hour)", short: "5h", percent: 28,
                                          resetsAt: now + 3 * hour + 30 * minute),
                                    Limit(key: "weekly", label: "Weekly (7-day)", short: "7d", percent: 52,
                                          resetsAt: now + 4 * day),
                                   ],
                                   readAt: now)
        return [openrouter, opencode, grok, codex, claude, antigravity]
    }

    static var state: DisplayState {
        var s = DisplayState()
        s.providers = providers
        s.now = now
        s.lastFetchMs = now - 5_000
        return s
    }
}
