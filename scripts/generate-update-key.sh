#!/bin/bash
# One-time setup for signed auto-updates. Run it yourself; it handles a secret.
#
#  1. Generates an Ed25519 signing key with CryptoKit.
#  2. Saves the private key to ~/.config/the-agentic-apple/update-signing-key
#     (mode 0600, outside the repository). BACK THIS FILE UP: if it is lost,
#     installed copies can only be updated by hand (or after a key rotation
#     shipped while the old key still works).
#  3. Stores it as the GitHub Actions secret UPDATE_SIGNING_KEY (via stdin,
#     never on a command line).
#  4. Adds the public key to Sources/AgenticCore/Update/UpdateKeys.swift, which
#     the app uses to verify every downloaded update.
#
# The private key is never printed.
#
# Key rotation is two-phase, so installed copies never meet a key they do not
# trust yet:
#   scripts/generate-update-key.sh --rotate    new key → …/update-signing-key.next,
#                                              its public key added to UpdateKeys.swift;
#                                              the secret keeps the OLD key.
#   (commit, release once — that release trusts both keys, signed with the old one)
#   scripts/generate-update-key.sh --activate  secret ← new key; old key kept as
#                                              …/update-signing-key.old
set -euo pipefail
MODE="${1:-init}"
cd "$(dirname "$0")/.."

KEY_DIR="$HOME/.config/the-agentic-apple"
KEY_FILE="$KEY_DIR/update-signing-key"
KEYS_SWIFT="Sources/AgenticCore/Update/UpdateKeys.swift"
REPO="${REPO:-crueber/the-agentic-apple}"

case "$MODE" in
  init)
    if [ -e "$KEY_FILE" ]; then
      echo "A key already exists at $KEY_FILE — refusing to overwrite it." >&2
      echo "To rotate, use --rotate (then --activate after one release)." >&2
      exit 1
    fi
    TARGET="$KEY_FILE" ;;
  --rotate)
    [ -e "$KEY_FILE" ] || { echo "No current key at $KEY_FILE; run without --rotate first." >&2; exit 1; }
    [ -e "$KEY_FILE.next" ] && { echo "$KEY_FILE.next already exists; --activate it or remove it." >&2; exit 1; }
    TARGET="$KEY_FILE.next" ;;
  --activate)
    [ -e "$KEY_FILE.next" ] || { echo "No staged key at $KEY_FILE.next; run --rotate first." >&2; exit 1; }
    gh secret set UPDATE_SIGNING_KEY -R "$REPO" < "$KEY_FILE.next"
    mv "$KEY_FILE" "$KEY_FILE.old"
    mv "$KEY_FILE.next" "$KEY_FILE"
    echo "✓ UPDATE_SIGNING_KEY now holds the new key; the previous key is kept at $KEY_FILE.old"
    echo "  Keep its public key in UpdateKeys.swift until every user has updated past it."
    exit 0 ;;
  *) echo "usage: $0 [--rotate | --activate]" >&2; exit 2 ;;
esac

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
GEN="$(mktemp -d)/genkey.swift"
cat > "$GEN" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
FileManager.default.createFile(atPath: CommandLine.arguments[1],
                               contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                               attributes: [.posixPermissions: 0o600])
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
PUB="$(umask 077; swift "$GEN" "$TARGET")"
rm -f "$GEN"
echo "✓ private key saved to $TARGET (0600) — back it up somewhere safe"

if [ "$MODE" = "init" ]; then
  gh secret set UPDATE_SIGNING_KEY -R "$REPO" < "$KEY_FILE"
  echo "✓ GitHub Actions secret UPDATE_SIGNING_KEY set on $REPO"
else
  echo "• the secret still holds the current key: commit UpdateKeys.swift, release once,"
  echo "  then run: scripts/generate-update-key.sh --activate"
fi

# Append the public key to the trusted list (keeps older keys for rotation).
python3 - "$KEYS_SWIFT" "$PUB" <<'PY'
import re, sys
path, pub = sys.argv[1], sys.argv[2]
src = open(path).read()
m = re.search(r'public static let trusted: \[String\] = \[(.*?)\]', src, re.S)
entries = [e.strip() for e in m.group(1).split(',') if e.strip()]
if f'"{pub}"' not in entries:
    entries.append(f'"{pub}"')
body = '\n' + ''.join(f'        {e},\n' for e in entries) + '    '
src = src[:m.start(1)] + body + src[m.end(1):]
open(path, 'w').write(src)
PY
echo "✓ public key added to $KEYS_SWIFT:"
echo "  $PUB"
echo
echo "Next: commit $KEYS_SWIFT, then tag a release."
