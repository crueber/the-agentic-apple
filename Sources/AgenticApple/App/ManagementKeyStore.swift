import Foundation
import Security
import AgenticCore

/// Writes and removes the OpenRouter management key in the login Keychain
/// (generic password, service `OpenRouterCollector.managementKeyService`,
/// account `default`). The app never reads the secret back: the collector reads
/// it through `/usr/bin/security`, and `isSaved` asks for attributes only.
///
/// The item is created with an access list trusting this app *and*
/// `/usr/bin/security`. That uses `SecAccessCreate` and
/// `SecTrustedApplicationCreateFromPath`, deprecated since macOS 10.10 but still
/// the only way to set a legacy (file-based) Keychain item's ACL. It matters
/// because the app is ad-hoc signed: its code identity changes with every
/// update, so an ACL naming only the app would prompt after each update.
/// `/usr/bin/security` is Apple-signed and stable, so collector reads stay
/// silent — the same pattern Claude Code's own item gets read with.
enum ManagementKeyStore {
    static let service = OpenRouterCollector.managementKeyService
    static let account = OpenRouterCollector.managementKeyAccount
    static let label = "The Agentic Apple — OpenRouter management key"

    enum StoreError: Error, CustomStringConvertible {
        case invalid(String)
        case keychain(OSStatus)

        var description: String {
            switch self {
            case .invalid(let m): return m
            case .keychain(let status):
                let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
                return "Keychain: " + Sanitize.plain(text, max: 160)
            }
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether an item exists. Attributes only: no secret is read, no prompt.
    static func isSaved() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Replace the item: delete, then add with a fresh access list for this
    /// build. Falls back to `SecItemUpdate` when the old item can't be deleted.
    static func save(_ raw: String) throws {
        if let problem = OpenRouterCollector.managementKeyProblem(raw) { throw StoreError.invalid(problem) }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(key.utf8)

        _ = SecItemDelete(baseQuery as CFDictionary)

        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrDescription as String] = "OpenRouter management key"
        if let access = makeAccess() { add[kSecAttrAccess as String] = access }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return }
            throw StoreError.keychain(update)
        }
        throw StoreError.keychain(status)
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw StoreError.keychain(status)
    }

    /// Trusted: this app (nil path = the caller) and `/usr/bin/security`.
    /// See the type comment for why the deprecated API is used.
    private static func makeAccess() -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        var tool: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath("/usr/bin/security", &tool) == errSecSuccess, let tool { apps.append(tool) }
        guard !apps.isEmpty else { return nil }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
