# Security

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(**Security → Report a vulnerability**) instead of a public issue. Include the
app version (`agentic-apple --version`), your macOS version, what you observed,
and the smallest reproduction you can. You should get an acknowledgement within
a few days.

## Trust model

The Agentic Apple is an unsandboxed, ad-hoc-signed, non-notarized menu bar app
that runs as you. It can read what you can read. Build it from this repository
(`scripts/install.sh`) and review changes like any other tool that handles your
agent credentials. A build downloaded from elsewhere has no Apple notarization
vouching for it; prefer building from source, or the DMG attached to this
repository's GitHub releases.

From 0.2.0 an installed copy also updates itself from those releases (see
[Updates](#updates) below). Every update must carry a signature from a key
compiled into the copy you already run, so the trust you placed in that copy
is what admits the next one. Turn this off with the **Install updates
automatically** setting (`autoUpdate`).

## Updates

### Signing keys

- Releases are signed with **Ed25519** (CryptoKit `Curve25519.Signing`). The
  signature, `The-Agentic-Apple-<version>.dmg.sig`, is the base64 of a
  signature over the exact bytes of `The-Agentic-Apple-<version>.dmg`.
- The public keys the app accepts are the base64 raw keys listed in
  `Sources/AgenticCore/Update/UpdateKeys.swift` (`UpdateKeys.trusted`),
  compiled into the app. There is **no runtime override**: no setting,
  environment variable, file or argument can add a key or change where the app
  looks for updates. With an empty list the app installs nothing.
- **Key custody.** `scripts/generate-update-key.sh` (run once by the
  maintainer) generates the key pair, writes the private key to
  `~/.config/the-agentic-apple/update-signing-key` (directory `0700`, file
  `0600`, outside the repository) and stores it as the GitHub Actions secret
  `UPDATE_SIGNING_KEY` over stdin. The private key is never printed, never on a
  command line and never committed. In CI it reaches
  `scripts/sign-update.swift` only through the environment of the signing
  steps.
- **Release gate.** `.github/workflows/release.yml` refuses to publish unless
  the tag equals `VERSION`, the secret is set, its public key is in the
  committed `UpdateKeys.swift`, and the signed DMG verifies against that file.
  The DMG and its `.sig` are uploaded in the same `gh release create` call.
- **Rotation.** Installed copies trust only the keys compiled into them, so a
  new key must first reach them in a release signed with the old one:
  1. `scripts/generate-update-key.sh --rotate` writes a new private key to
     `~/.config/the-agentic-apple/update-signing-key.next` and **appends** its
     public key to `UpdateKeys.trusted`. The `UPDATE_SIGNING_KEY` secret keeps
     the old key.
  2. Commit and release: that bridging release trusts both keys and is signed
     with the old one, so every installed copy accepts it.
  3. `scripts/generate-update-key.sh --activate` switches the secret to the new
     key and keeps the old one as `update-signing-key.old`. Keep the old public
     key in the list until every installed copy has updated past the bridging
     release, then remove it.

  A compromised key is retired the same way, but copies that never update
  past the bridging release keep trusting it: say so in a security advisory.
- **Lost key.** Without a trusted private key no further update can be
  installed automatically; users must install the next release by hand.

### What the app checks before installing

1. The release comes from `api.github.com` (this repository's
   `releases/latest`). Drafts and prereleases are ignored; the tag must be a
   plain version strictly newer than the running one, and the release must
   carry both `The-Agentic-Apple-<version>.dmg` and its `.dmg.sig`.
2. Both assets are downloaded over HTTPS into a fresh `0700` work directory
   (files created exclusively, mode `0600`). The first URL and every redirect
   must be on `github.com` or `*.githubusercontent.com` (at most five hops);
   anything else is refused. No cookies, cache or credentials. The signature is
   capped at 4 KB and the disk image at 64 MB, and the size must match the one
   the release lists.
3. The signature must verify against one of `UpdateKeys.trusted` over the whole
   downloaded file **before anything mounts it**. With no trusted keys the
   app installs nothing.
4. The image is attached read-only (`hdiutil attach -readonly -nobrowse
   -noautoopen`) at a private mount point and always detached again. It must
   hold exactly one `.app` (a real directory, not a symlink), whose
   `Info.plist` has the bundle ID `com.crueber.agentic-apple` and a version
   equal to the release's and **strictly newer** than the running copy. This
   in-bundle check is the replay defence: an older, validly signed release
   cannot be served to downgrade you.
5. `codesign --verify --deep --strict` on the mounted app; then
   `ditto --noqtn` to a hidden staging folder beside the installed bundle
   (same volume). The updater removes the quarantine attribute only from that
   verified staged copy; it does not otherwise touch Gatekeeper or any other
   file. The staged copy is verified with `codesign` again, and its own
   `agentic-apple --version` must print the expected version.
6. The installed bundle is renamed to a hidden backup and the staged copy
   renamed into its place. If any step fails, the old app is restored and the
   staged copy removed. The app then relaunches: it asks LaunchServices to start
   the new bundle as a new instance (passing only its own PID, in
   `AGENTIC_APPLE_RELAUNCH_AFTER`), and quits once that launch is confirmed; the
   new instance waits for the old PID to exit before its single-instance check.
   Only if LaunchServices refuses does the fixed `/bin/sh` helper below take
   over. The new version removes the
   backup and any leftover staging folder when it starts.

### Where it never installs

Only an installed copy in a writable Applications folder (`/Applications` or
`~/Applications`) updates itself. A copy run from a disk image, a translocated
path or `dist/`, `swift run`, the command-line modes (`--text`, `--json`, …)
and the self-test never install an update. Where the folder is not writable,
a manual check only reports the new version.

## What the app reads

| Agent | Read | Never read |
| --- | --- | --- |
| OpenRouter | `OPENROUTER_API_KEY`; the configured auth file or `OPENROUTER_AUTH_FILE`; OpenCode's `auth.json`; the output of `opencode auth export` | — |
| OpenCode | the local API through `opencode api GET /api/experimental/usage/limits`; `opencode.db` through `/usr/bin/sqlite3 -readonly`, selecting only message counts and token sums | message text |
| Grok | `~/.grok/logs/unified.jsonl` (the billing snapshot line); `~/.grok/sessions/**/usage.json` (numeric ledgers); Grok Bot's small cached `*.blob` JSON (≤ 64 KB) | `~/.grok/auth.json`, prompts, responses, Grok Bot's session or cookies |
| Codex | `~/.codex/auth.json`, parsed only for `auth_mode` and whether an API key field is non-empty; `cli_auth_credentials_store` in `~/.codex/config.toml`; the app-server's rate-limit answer | any token value |
| Claude | the Keychain item `Claude Code-credentials` (via `/usr/bin/security`) or `~/.claude/.credentials.json`; the tier in `~/.claude.json`; today's transcripts under `~/.claude/projects/**/*.jsonl` | — (transcripts are parsed in memory; only counts and id hashes are kept) |

No prompt text, response text or session content is stored or displayed.

## Credentials

- **Read-only.** Keys and tokens are read at request time, held in memory for
  that request, and dropped. The app never refreshes Claude's OAuth token,
  never writes any credential back, and never stores one in its cache, its
  defaults domain or a log.
- **Never on a command line.** No key or token is passed as an argument to
  any process. `security find-generic-password -w` prints the Claude
  credential to the app over a pipe.
- **Header only.** The OpenRouter key is sent only in an HTTPS
  `Authorization` header to `openrouter.ai`; Claude's access token only in one
  to `api.anthropic.com`. Error text from OpenRouter is scrubbed of the key
  before it is displayed.
- **Keychain.** The Claude item is read through Apple's `/usr/bin/security`
  so the user's **Always Allow** applies to that system tool rather than to an
  ad-hoc signature that changes on every rebuild. Denying access is safe: the
  app falls back to the credentials file or leaves Claude out.
- **Never printed.** `agentic-apple --text` and `--json` print display data
  only; the OpenRouter key appears at most as a three-character tail
  (`key …2eb`).

## Network access

The app makes requests of its own to three destinations:

- OpenRouter:
  - `GET https://openrouter.ai/api/v1/key`
  - `GET https://openrouter.ai/api/v1/credits` (optional)
- Anthropic: `GET https://api.anthropic.com/api/oauth/usage`
- GitHub, for updates (about 2 minutes after launch, then every 6 hours, only
  when `autoUpdate` is on; or when you choose **Check for Updates…**):
  - `GET https://api.github.com/repos/crueber/the-agentic-apple/releases/latest`
  - the release's `.dmg` and `.dmg.sig` from `github.com`, redirected to
    `release-assets.githubusercontent.com`

The usage requests go through an ephemeral `URLSession`: HTTPS only, redirects
not followed, no cookies, no URL cache, a 15-second timeout and a 1 MB
response cap. The update requests are HTTPS only, follow redirects only to
`github.com` and `*.githubusercontent.com`, send no cookies, credentials or
identifiers beyond a generic `User-Agent` (`TheAgenticApple-Updater`), and are
size-capped (4 KB signature, 64 MB disk image).

`opencode` (its local API, its standalone server, `auth export`) and the Codex
app-server make their own requests under their own credentials when the app
starts them. There is no telemetry and no analytics; the update check sends
nothing about you or your agents.

## Processes the app starts

| Executable | Arguments | When |
| --- | --- | --- |
| your login shell (`$SHELL`, else `/bin/zsh`) | `-l -i -c` with a fixed script printing `PATH` and an allowlist of variables | once per launch, in its own session with no terminal, bounded by a timeout |
| `/usr/bin/security` | `find-generic-password -s "Claude Code-credentials" -w` | each refresh |
| `/usr/bin/sqlite3` | `-readonly -json -cmd ".timeout 2000" <opencode.db> <fixed query>` | each refresh, when OpenCode's store exists |
| `opencode` | `api GET /api/experimental/usage/limits`, then `api --standalone GET …`; `auth export openrouter`, `auth export` | each refresh |
| `codex` | `-s read-only -a on-request app-server` | each refresh, when Codex is signed in to a plan; shut down after it answers |
| `mise` | `which codex` with `MISE_OFFLINE=1` | when no real `codex` is on the search path |
| `/usr/bin/hdiutil` | `attach -readonly -nobrowse -noautoopen` and `detach` of the downloaded disk image, only after its signature has verified | during an update |
| `/usr/bin/codesign` | `--verify --deep --strict` on the mounted app, then `--verify` on the staged copy | during an update |
| `/usr/bin/ditto` | `--noqtn` copy of the new app from the image to the staging folder | during an update |
| the staged `agentic-apple` | `--version` | during an update, to confirm the staged version |
| `/usr/bin/open` | launch the updated app | after an update, only if LaunchServices refused the direct relaunch |
| `/bin/sh` | a fixed relaunch helper script (no outside text in it) that waits for the old copy to quit, then opens the new one | fallback only, as above; it outlives the app by design |

Processes are started directly with an argument list; no outside text is ever
interpolated into a command (the only shells involved are the fixed `PATH`
probe and the fixed relaunch helper above). Each, except the relaunch helper that must outlive the app, has a
timeout (killed after it), stdin closed or fed a fixed payload, and output
capped (8 MB stdout, 256 KB stderr); children run in their own process group,
which is killed as a whole on timeout. The login-shell probe imports only `PATH`
and the variables listed in the README (`OPENROUTER_API_KEY`, `CODEX_HOME`,
`CLAUDE_CONFIG_DIR`, …); their values are never logged. It runs your shell's
startup files once; if that is not acceptable, launch the app from a context
whose `PATH` already holds your tools and set the command paths in Settings.

The `opencode`, `codex` and Grok home paths in Settings are yours to set; the
app runs whatever executable you point it at.

## What the app writes

- `~/Library/Caches/com.crueber.agentic-apple/` — directory mode `0700`,
  files `0600`, written atomically:
  - `usage.json`: displayed numbers, plan labels, statuses, hints and errors
    (sanitised), reset times, activity counts, the masked OpenRouter key label,
    and the OpenRouter previous-cycle baseline;
  - `claude-activity.json`: today's incremental transcript scan — transcript
    file paths, sizes, byte offsets, counts and 64-bit FNV hashes of message and
    request ids. No text.
- The user defaults domain `com.crueber.agentic-apple` (settings only).
- A login item, when you turn on **Launch at Login** (`SMAppService`).
- `~/Library/Logs/The Agentic Apple/update.log` (directory `0700`, file
  `0600`, rotated at 256 KB with one `.1` kept): what the updater did —
  versions, steps, PIDs and plain error text. Never a key, token or agent data.
- During an update only: the downloaded image and signature, and the mount
  point, in a fresh `0700` directory under the temporary folder, removed
  afterwards; and a hidden staging copy of the new app
  (`.The Agentic Apple.update-<hex>.app`) and backup of the old one
  (`.The Agentic Apple.backup-<hex>.app`) beside the installed bundle. A failed
  update restores the old app and removes the staging copy; after a
  successful one the new version removes the backup when it starts.

`scripts/install.sh` additionally writes the app bundle to `~/Applications` (or
`$INSTALL_DIR`) and a symlink at `~/.local/bin/agentic-apple`.

## Text and inputs

Every string that comes from a file, a command or a network response is
bounded and neutralised before display (control characters removed, angle
brackets replaced). Percentages are clamped to 0–100, numbers must be finite,
collection sizes are bounded, files are size-checked before they are read, and
the cache is re-sanitised when it is loaded. A cache with timestamps from the
future is distrusted.

## Preview images

`docs/images/*.png` are rendered offline by `agentic-apple --render-preview`
from an invented fixture compiled into the app. No real key, account,
workspace, spend, credit or usage figure appears in them, and the renderer
touches no agent, Keychain, cache or network. Every test fixture under
`Tests/Fixtures/` is synthetic as well.

## Supported versions

Only the latest release is supported. Installed copies from 0.2.0 on update
themselves (unless `autoUpdate` is off); 0.1.0 has no updater, so install
0.2.0 by hand once. A copy built from source picks up fixes from `main` with
`git pull && scripts/install.sh`.
