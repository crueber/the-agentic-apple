import Foundation

/// The six agents, in the default bar order.
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case openrouter, opencode, grok, codex, claude, antigravity

    public static let defaultOrder: [ProviderID] = [.openrouter, .opencode, .grok, .codex, .claude, .antigravity]

    public var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .opencode: return "OpenCode"
        case .grok: return "Grok"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }
}

/// One limit window (a session, a week, a model's own allowance…).
public struct Limit: Codable, Equatable, Sendable {
    /// Stable key: session, weekly, monthly, review, spend, fable/<model>, other…
    public var key: String
    /// Panel title, e.g. "Session (5-hour)".
    public var label: String
    /// Bar/compact label, e.g. "5h", "7d".
    public var short: String
    /// 0…100, already clamped.
    public var percent: Double
    /// Epoch milliseconds, 0 when unknown.
    public var resetsAt: Double
    /// The source marks this window as at its limit.
    public var limited: Bool
    /// The reading is past its expiry (e.g. Grok Bot cache).
    public var stale: Bool
    /// A dollar value instead of a meter (OpenRouter's credits left, an unlimited
    /// key's monthly spend). nil = an ordinary percentage window. Finite, ≥ 0.
    public var amount: Double?

    public init(key: String, label: String, short: String, percent: Double,
                resetsAt: Double = 0, limited: Bool = false, stale: Bool = false, amount: Double? = nil) {
        self.key = key
        self.label = label
        self.short = short
        self.percent = min(100, max(0, percent.isFinite ? percent : 0))
        self.resetsAt = resetsAt
        self.limited = limited
        self.stale = stale
        self.amount = amount.flatMap { $0.isFinite ? max(0, $0) : nil }
    }
}

/// Local activity (today, or this week for Grok).
public struct Activity: Codable, Equatable, Sendable {
    public var period: String   // "today" | "week"
    public var prompts: Int
    public var tokens: Int

    public init(period: String = "today", prompts: Int = 0, tokens: Int = 0) {
        self.period = period
        self.prompts = max(0, prompts)
        self.tokens = max(0, tokens)
    }

    public static let empty = Activity()
}

/// OpenRouter account-wide: the average monthly spend of the N calendar months
/// before `month` (UTC), from OpenRouter's analytics. Cached with the
/// provider, so it is queried at most once a month.
public struct MonthlyBaseline: Codable, Equatable, Sendable {
    /// "2026-11": the month this is the baseline *for* (the current month when read).
    public var month: String
    /// Dollars per month, > 0.
    public var average: Double
    /// Months averaged (N).
    public var months: Int
    /// "Sep–Oct".
    public var label: String

    public init(month: String, average: Double, months: Int = 2, label: String) {
        self.month = month
        self.average = average
        self.months = months
        self.label = label
    }
}

/// OpenRouter's money block.
public struct Money: Codable, Equatable, Sendable {
    /// `label` of the account-wide (management key) block: every key's spend.
    public static let accountWideLabel = "All keys"

    public var label: String          // masked key label, e.g. "key …demo", or "All keys"
    public var limit: Double?         // key limit in dollars (nil = none)
    public var spend: Double          // this cycle's spend
    public var credits: Double?       // account credits left
    public var totalCredits: Double?  // account credits purchased
    public var resetInterval: String  // "monthly", "weekly", "daily", ""
    public var resetsAt: Double       // epoch ms
    /// Account-wide only: the previous N months' average spend (analytics), nil when unknown.
    public var baseline: MonthlyBaseline?
    /// Account-wide only: the usage meter's N (`openrouterAverageMonths`) at
    /// collection time; 0 = meter off; nil (older caches) = 2.
    public var averageMonths: Int?

    public init(label: String = "", limit: Double? = nil, spend: Double = 0, credits: Double? = nil,
                totalCredits: Double? = nil, resetInterval: String = "", resetsAt: Double = 0,
                baseline: MonthlyBaseline? = nil, averageMonths: Int? = nil) {
        self.label = label
        self.limit = limit
        self.spend = spend
        self.credits = credits
        self.totalCredits = totalCredits
        self.resetInterval = resetInterval
        self.resetsAt = resetsAt
        self.baseline = baseline
        self.averageMonths = averageMonths.map { min(12, max(0, $0)) }
    }
}

/// OpenCode Console budgets.
public struct Budget: Codable, Equatable, Sendable {
    public var label: String
    public var spend: Double
    public var limit: Double
    public var percent: Double

    public init(label: String, spend: Double, limit: Double, percent: Double) {
        self.label = label
        self.spend = spend
        self.limit = limit
        self.percent = min(100, max(0, percent.isFinite ? percent : 0))
    }
}

/// The normalised shape every provider collector produces — the same shape as
/// the reference plugin's `collect.js`.
public struct Provider: Codable, Equatable, Sendable, Identifiable {
    public var id: ProviderID
    public var name: String
    /// Has a plan, key or usage on this machine. Unavailable agents stay out of the bar.
    public var available: Bool
    public var tier: String
    public var status: String
    public var hint: String
    public var error: String
    public var source: String
    public var limits: [Limit]
    public var activity: Activity
    public var money: Money?
    public var budgets: [Budget]
    /// Epoch ms of when the numbers were read (0 = unknown). Grok uses the snapshot age.
    public var readAt: Double

    public init(id: ProviderID, available: Bool = false, tier: String = "", status: String = "",
                hint: String = "", error: String = "", source: String = "", limits: [Limit] = [],
                activity: Activity = .empty, money: Money? = nil, budgets: [Budget] = [], readAt: Double = 0) {
        self.id = id
        self.name = id.displayName
        self.available = available
        self.tier = tier
        self.status = status
        self.hint = hint
        self.error = error
        self.source = source
        self.limits = limits
        self.activity = activity
        self.money = money
        self.budgets = budgets
        self.readAt = readAt
    }
}

/// Environment every collector gets: where things live, and overrides from Settings.
/// Tests point `home` at a temporary directory and the command paths at fakes.
public struct CollectorContext: Sendable {
    public var home: URL
    public var environment: [String: String]
    /// Search PATH for external tools (already merged with the login-shell PATH).
    public var searchPath: [String]
    public var opencodeCommand: String
    public var codexCommand: String
    public var claudeCommand: String
    public var grokHome: String
    public var botHome: String
    public var antigravityHome: String
    public var authFile: String
    public var now: Date
    /// Inject HTTP for tests. nil = real network.
    public var http: HTTPClient?
    /// OpenRouter account-wide: the baseline from the last collection (the
    /// cache), so analytics is not queried again within the same month.
    public var openrouterBaseline: MonthlyBaseline?
    /// OpenRouter account-wide usage meter: months to average (1–12), 0 = off.
    public var openrouterAverageMonths: Int = 2

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                searchPath: [String] = [],
                opencodeCommand: String = "", codexCommand: String = "", claudeCommand: String = "",
                grokHome: String = "", botHome: String = "", antigravityHome: String = "", authFile: String = "",
                now: Date = Date(), http: HTTPClient? = nil, openrouterBaseline: MonthlyBaseline? = nil) {
        self.home = home
        self.environment = environment
        self.searchPath = searchPath
        self.opencodeCommand = opencodeCommand
        self.codexCommand = codexCommand
        self.claudeCommand = claudeCommand
        self.grokHome = grokHome
        self.botHome = botHome
        self.antigravityHome = antigravityHome
        self.authFile = authFile
        self.now = now
        self.http = http
        self.openrouterBaseline = openrouterBaseline
    }

    public var nowMs: Double { now.timeIntervalSince1970 * 1000 }
}

/// Each agent implements this. `collect` never throws: failures become `error`.
public protocol ProviderCollector: Sendable {
    var id: ProviderID { get }
    func collect(_ context: CollectorContext) async -> Provider
}
