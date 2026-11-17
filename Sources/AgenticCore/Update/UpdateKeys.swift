import Foundation

/// Ed25519 public keys (raw 32 bytes, base64) whose signatures the updater
/// accepts. `scripts/generate-update-key.sh` appends to this list; keep old
/// keys here until every installed copy has updated past a rotation.
/// There is deliberately no runtime override.
public enum UpdateKeys {
    public static let trusted: [String] = [
        "JRtulDSNOQf3jmvoVbyM6Di/m8TgALFS7U2o45sRnsQ=",
    ]
}
