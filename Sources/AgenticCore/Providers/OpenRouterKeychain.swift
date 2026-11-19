import Foundation

/// The OpenRouter management key's Keychain item, handled entirely through
/// `/usr/bin/security` so that `security` is the item's creator and trusted
/// application. Its later reads (`find-generic-password -w`) then never prompt,
/// whatever the app's own ad-hoc code signature is after an update. (An item
/// created by the app through `SecItemAdd` is bound to the app's signature —
/// its partition list — so every `security` read of it prompts.)
///
/// - `save`: `security -i` (interactive), commands on **stdin**, never argv:
///   `delete-generic-password -s <service> -a default`, then
///   `add-generic-password -U -s <service> -a default -l "<label>" -w <key>`.
///   `security -i` splits on whitespace, groups `"…"`/`'…'`, honours `\`, has
///   no `quit` (EOF ends it) and exits with the *last* command's status. The
///   key is limited to `allowedKeyCharacters` (no space, quote or backslash),
///   so it is always exactly one token.
/// - `remove`: `security delete-generic-password -s <service> -a default`.
/// - `isSaved`: `security find-generic-password -s <service> -a default`
///   (no `-w`: attributes only, no secret, no prompt).
/// - `read`: `security find-generic-password -s <service> -a default -w`;
///   exit 44 (not found) = absent; another failure = denied (cached by
///   `ManagementKeyMemo` so a refused prompt is not repeated); a timeout is not.
public struct KeychainTool: Sendable {
    public typealias Runner = @Sendable (_ arguments: [String], _ input: Data?) -> CommandResult

    public var run: Runner

    public init(run: @escaping Runner) { self.run = run }

    public static let securityPath = "/usr/bin/security"
    public static let itemLabel = "The Agentic Apple \u{2014} OpenRouter management key"
    /// `security`'s exit status for errSecItemNotFound.
    public static let notFoundStatus: Int32 = 44

    public static let live = KeychainTool { arguments, input in
        Shell.run(securityPath, arguments, input: input, timeout: 15)
    }

    var service: String { OpenRouterCollector.managementKeyService }
    var account: String { OpenRouterCollector.managementKeyAccount }

    public enum ReadResult: Equatable, Sendable {
        case key(String)
        case absent
        /// `security` answered with an error other than "not found" (a refused
        /// or cancelled prompt, an item it may not read).
        case denied
        /// `security` could not be started or did not answer in time.
        case unavailable
    }

    /// The stdin script for `security -i`. Only for a key that passed the
    /// shape check; nil otherwise.
    public static func saveScript(_ key: String) -> String? {
        guard OpenRouterCollector.managementKeyProblem(key) == nil else { return nil }
        let service = OpenRouterCollector.managementKeyService, account = OpenRouterCollector.managementKeyAccount
        return "delete-generic-password -s \(service) -a \(account)\n"
            + "add-generic-password -U -s \(service) -a \(account) -l \"\(itemLabel)\" -w \(key)\n"
    }

    /// nil on success, else a display-safe reason (never the key).
    public func save(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = OpenRouterCollector.managementKeyProblem(key) { return problem }
        guard let script = Self.saveScript(key) else { return "That doesn't look like an OpenRouter key" }
        let r = run(["-i"], Data(script.utf8))
        if r.timedOut || !r.launched { return "The Keychain didn't answer; try again" }
        if r.status != 0 { return "The Keychain refused to save the key (security exit \(r.status))" }
        return nil
    }

    /// nil on success (or nothing to remove), else a display-safe reason.
    public func remove() -> String? {
        let r = run(["delete-generic-password", "-s", service, "-a", account], nil)
        if r.timedOut || !r.launched { return "The Keychain didn't answer; try again" }
        if r.status != 0 && r.status != Self.notFoundStatus {
            return "The Keychain refused to remove the key (security exit \(r.status))"
        }
        return nil
    }

    public func isSaved() -> Bool {
        run(["find-generic-password", "-s", service, "-a", account], nil).ok
    }

    public func read() -> ReadResult {
        let r = run(["find-generic-password", "-s", service, "-a", account, "-w"], nil)
        if r.timedOut || !r.launched { return .unavailable }
        if r.status == Self.notFoundStatus { return .absent }
        guard r.ok else { return .denied }
        guard r.stdout.count <= 4096, let key = OpenRouterCollector.normalizedManagementKey(r.stdoutText) else { return .absent }
        return .key(key)
    }
}

/// Read once per process: the first Keychain answer (key, absent or denied) is
/// kept in memory, so refreshes never touch the Keychain again within a run.
/// Settings › Save / Remove set it directly. An `unavailable` read is not kept.
public final class ManagementKeyMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: KeychainTool.ReadResult?
    private var loads = 0

    public init() {}

    public static let shared = ManagementKeyMemo()

    /// The cached answer, or `load()` once (outside the lock: it may block).
    public func resolve(_ load: () -> KeychainTool.ReadResult) -> KeychainTool.ReadResult {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()
        let fresh = load()
        lock.lock(); defer { lock.unlock() }
        loads += 1
        if let cached { return cached }   // set by Save/Remove meanwhile
        if fresh != .unavailable { cached = fresh }
        return fresh
    }

    public func set(_ value: KeychainTool.ReadResult?) { lock.lock(); cached = value; lock.unlock() }
    public func invalidate() { set(nil) }

    /// The last read was refused (an old app-created item that prompts).
    public var readWasDenied: Bool { lock.lock(); defer { lock.unlock() }; return cached == .denied }
    /// How many times `resolve` actually loaded (tests).
    public var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
}

/// Thrown by a management-key reader; `message` is shown as the provider error.
public struct ManagementKeyReadError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

extension OpenRouterCollector {
    static let unreadableKeychain = "The OpenRouter management key could not be read from the Keychain"
    public static let reSaveHint = "Re-save the key once to stop Keychain prompts"

    /// The app's reader: the memo, else one `security … -w`.
    public static func defaultManagementKeyReader(memo: ManagementKeyMemo = .shared,
                                                  tool: KeychainTool = .live) -> ManagementKeyReader {
        return { _ in
            switch memo.resolve({ tool.read() }) {
            case .key(let key): return key
            case .absent: return nil
            case .denied: throw ManagementKeyReadError(unreadableKeychain + ". " + reSaveHint + " (Settings \u{203A} Advanced).")
            case .unavailable: throw ManagementKeyReadError(unreadableKeychain)
            }
        }
    }
}
