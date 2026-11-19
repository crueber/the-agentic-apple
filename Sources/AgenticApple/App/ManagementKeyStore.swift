import Foundation
import AgenticCore

/// Saves and removes the OpenRouter management key through `/usr/bin/security`
/// (`KeychainTool`), so `security` owns the item and the collector's reads
/// never prompt. The key goes to `security -i` on stdin, never on a command
/// line. The process-wide `ManagementKeyMemo` is updated on every change, so
/// the next refresh uses the new key without reading the Keychain again.
enum ManagementKeyStore {
    static var tool: KeychainTool = .live
    static var memo: ManagementKeyMemo { .shared }

    /// nil on success, else a display-safe reason.
    static func save(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = tool.save(key) { memo.invalidate(); return failure }
        memo.set(.key(key))
        return nil
    }

    static func remove() -> String? {
        let failure = tool.remove()
        if failure == nil { memo.set(.absent) } else { memo.invalidate() }
        return failure
    }

    /// Attributes only (no `-w`): no secret is read, no prompt.
    static func isSaved() -> Bool { tool.isSaved() }

    /// A saved key whose read was refused: an item created by 1.1.0's first
    /// build (bound to the app's old signature) that prompts on every read.
    static var needsResave: Bool { memo.readWasDenied }
}
