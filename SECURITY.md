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
vouching for it; prefer building from source.

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

The app makes exactly three kinds of request of its own:

- `GET https://openrouter.ai/api/v1/key`
- `GET https://openrouter.ai/api/v1/credits` (optional)
- `GET https://api.anthropic.com/api/oauth/usage`

All go through an ephemeral `URLSession`: HTTPS only, redirects not followed,
no cookies, no URL cache, a 15-second timeout and a 1 MB response cap.

`opencode` (its local API, its standalone server, `auth export`) and the Codex
app-server make their own requests under their own credentials when the app
starts them. There is no telemetry, no analytics and no update check.

## Processes the app starts

| Executable | Arguments | When |
| --- | --- | --- |
| your login shell (`$SHELL`, else `/bin/zsh`) | `-l -i -c` with a fixed script printing `PATH` and an allowlist of variables | once per launch, in its own session with no terminal, bounded by a timeout |
| `/usr/bin/security` | `find-generic-password -s "Claude Code-credentials" -w` | each refresh |
| `/usr/bin/sqlite3` | `-readonly -json -cmd ".timeout 2000" <opencode.db> <fixed query>` | each refresh, when OpenCode's store exists |
| `opencode` | `api GET /api/experimental/usage/limits`, then `api --standalone GET …`; `auth export openrouter`, `auth export` | each refresh |
| `codex` | `-s read-only -a on-request app-server` | each refresh, when Codex is signed in to a plan; shut down after it answers |
| `mise` | `which codex` with `MISE_OFFLINE=1` | when no real `codex` is on the search path |

Processes are started directly with an argument list; no outside text is ever
interpolated into a command (the only shell involved is the fixed `PATH` probe
above). Each has a
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

Fixes land on `main`. Rebuild with `scripts/install.sh` from an updated
checkout to pick them up.
