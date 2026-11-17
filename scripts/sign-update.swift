// Sign and verify release disk images for the in-app updater.
//
//   UPDATE_SIGNING_KEY=… swift scripts/sign-update.swift sign <dmg>
//       Writes <dmg>.sig: the base64 Ed25519 signature over the raw DMG bytes.
//   UPDATE_SIGNING_KEY=… swift scripts/sign-update.swift check <UpdateKeys.swift>
//       Fails unless the key's public half is in the trusted list.
//   swift scripts/sign-update.swift verify <dmg> <sig> <UpdateKeys.swift>
//       Fails unless one of the trusted public keys verifies the signature.
//
// The private key (base64 of the raw 32-byte Curve25519.Signing key, as
// written by scripts/generate-update-key.sh) is read only from the environment
// variable UPDATE_SIGNING_KEY — never from the command line — and never printed.
// CryptoKit and Foundation only.
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    fail("""
    usage:
      UPDATE_SIGNING_KEY=… swift scripts/sign-update.swift sign <dmg>
      UPDATE_SIGNING_KEY=… swift scripts/sign-update.swift check <UpdateKeys.swift>
      swift scripts/sign-update.swift verify <dmg> <sig> <UpdateKeys.swift>
    """, code: 2)
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

func trimmed(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The private key from UPDATE_SIGNING_KEY. Error messages never include it.
func privateKey() -> Curve25519.Signing.PrivateKey {
    let raw = (ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { fail("UPDATE_SIGNING_KEY is not set or empty") }
    guard let bytes = Data(base64Encoded: raw), bytes.count == 32 else {
        fail("UPDATE_SIGNING_KEY is not base64 of a 32-byte Ed25519 private key")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        fail("UPDATE_SIGNING_KEY is not a valid Ed25519 private key")
    }
    return key
}

/// The base64 strings inside `public static let trusted: [String] = [ … ]`,
/// skipping `//` comments. Fails on anything that is not a 32-byte key.
func trustedKeys(_ swiftPath: String) -> [String] {
    let source = String(decoding: readFile(swiftPath), as: UTF8.self)
    let marker = "public static let trusted: [String] = ["
    guard let start = source.range(of: marker),
          let end = source.range(of: "]", range: start.upperBound..<source.endIndex)
    else { fail("no `\(marker) … ]` list in \(swiftPath)") }
    // Scan characters so a "//" inside a base64 string is not taken for a comment.
    let body = Array(source[start.upperBound..<end.lowerBound])
    var keys: [String] = []
    var i = 0
    while i < body.count {
        if body[i] == "/", i + 1 < body.count, body[i + 1] == "/" {
            while i < body.count, body[i] != "\n" { i += 1 }
        } else if body[i] == "\"" {
            var j = i + 1
            while j < body.count, body[j] != "\"", body[j] != "\n" { j += 1 }
            guard j < body.count, body[j] == "\"" else {
                fail("unterminated string in the trusted list of \(swiftPath)")
            }
            let key = String(body[(i + 1)..<j])
            guard let bytes = Data(base64Encoded: key), bytes.count == 32 else {
                fail("trusted entry \"\(key)\" is not base64 of a 32-byte public key")
            }
            keys.append(key)
            i = j + 1
        } else {
            i += 1
        }
    }
    return keys
}

func requireTrusted(_ swiftPath: String) -> [String] {
    let keys = trustedKeys(swiftPath)
    if keys.isEmpty {
        fail("the trusted key list in \(swiftPath) is empty — run scripts/generate-update-key.sh and commit the file")
    }
    return keys
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch (command, args.count) {
case ("sign", 2):
    let dmgPath = args[1]
    let key = privateKey()
    let dmg = readFile(dmgPath)
    guard let signature = try? key.signature(for: dmg) else { fail("signing failed") }
    guard key.publicKey.isValidSignature(signature, for: dmg) else { fail("self-check of the new signature failed") }
    let sigPath = dmgPath + ".sig"
    guard FileManager.default.createFile(atPath: sigPath, contents: Data(signature.base64EncodedString().utf8)) else {
        fail("cannot write \(sigPath)")
    }
    print("✓ signed \(dmgPath) → \(sigPath)")
    print("  public key \(key.publicKey.rawRepresentation.base64EncodedString())")

case ("check", 2):
    let keys = requireTrusted(args[1])
    let pub = privateKey().publicKey.rawRepresentation.base64EncodedString()
    guard keys.contains(pub) else {
        fail("the public key of UPDATE_SIGNING_KEY (\(pub)) is not in the trusted list of \(args[1])")
    }
    print("✓ UPDATE_SIGNING_KEY matches trusted key \(pub)")

case ("verify", 4):
    let (dmgPath, sigPath, swiftPath) = (args[1], args[2], args[3])
    let keys = requireTrusted(swiftPath)
    let dmg = readFile(dmgPath)
    guard let signature = Data(base64Encoded: trimmed(readFile(sigPath))), signature.count == 64 else {
        fail("\(sigPath) is not base64 of a 64-byte Ed25519 signature")
    }
    for key in keys {
        guard let bytes = Data(base64Encoded: key),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { continue }
        if pub.isValidSignature(signature, for: dmg) {
            print("✓ \(dmgPath) verified by trusted key \(key)")
            exit(0)
        }
    }
    fail("no trusted key in \(swiftPath) verifies \(sigPath) for \(dmgPath)")

default:
    usage()
}
