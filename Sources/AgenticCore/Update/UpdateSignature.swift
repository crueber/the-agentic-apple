import CryptoKit
import Foundation

/// Ed25519 (CryptoKit `Curve25519.Signing`) verification of a downloaded update.
///
/// Public API:
/// - `UpdateSignature.publicKeys(_:)` — base64 raw 32-byte keys → keys (bad entries dropped)
/// - `UpdateSignature.decodeSignature(_:)` — the `.sig` asset (base64 text, whitespace
///   tolerated) → the 64 raw signature bytes
/// - `UpdateSignature.verify(_:signature:trustedKeys:)` — true when any trusted key verifies
///
/// An empty or unusable trusted list verifies nothing.
public enum UpdateSignature {
    public static func publicKeys(_ base64Keys: [String]) -> [Curve25519.Signing.PublicKey] {
        base64Keys.compactMap { s in
            guard let raw = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
    }

    public static func decodeSignature(_ file: Data) -> Data? {
        guard file.count <= UpdateFeed.maxSignatureBytes,
              let text = String(data: file, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text), raw.count == 64 else { return nil }
        return raw
    }

    public static func verify(_ message: Data, signature: Data, trustedKeys: [String]) -> Bool {
        guard signature.count == 64 else { return false }
        for key in publicKeys(trustedKeys) where key.isValidSignature(signature, for: message) {
            return true
        }
        return false
    }

    /// True when the trusted list holds at least one usable key.
    public static func isConfigured(_ trustedKeys: [String]) -> Bool { !publicKeys(trustedKeys).isEmpty }
}
