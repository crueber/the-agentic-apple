# Changelog

## 1.2.2 — 2026-11-28

- **No empty `0%` Grok placeholder.** When only Grok Bot is present (without a
  Grok CLI billing log), Grok now shows **Grok Bot weekly** alone instead of
  fabricating a `0%` **Weekly limit** row. Once the Grok CLI writes a billing
  snapshot, **Weekly limit** appears beside it with its real percentage and
  reset time.
- **Manual refresh is never blocked by automatic polls.** Clicking **Refresh**
  (or pressing `R`) now tracks its 30-second cooldown separately from
  background polls, so an automatic refresh that just ran can no longer
  silently swallow a manual click. During the 30-second manual cooldown, the
  Refresh button and **Refresh Now** menu item visibly disable with a tooltip.

## 1.2.1 — 2026-11-27

- **Antigravity Session & Weekly limits.** Send a versioned `User-Agent`
  (`antigravity/acp/2.0.0`) to `v1internal:retrieveUserQuotaSummary` so Google
  returns the primary **Gemini Models** quota group instead of dropping it and
  returning only third-party (`Claude & GPT`) buckets; also read `bucketId` on
  returned buckets.
- Map Antigravity's primary 5-hour and weekly buckets to **Session (5-hour)**
  (`5h`) and **Weekly (7-day)** (`7d`), and omit untouched 0% third-party
  (`Claude & GPT`) buckets when the primary limits are present.

## 1.2.0 — 2026-11-27

- **Antigravity support.** Added Google Antigravity (CLI, Desktop App and IDE)
  with its own monochrome arch mark, menu bar meters, panel section and
  **Settings → Advanced → Antigravity home** override (`antigravityHome` /
  `ANTIGRAVITY_HOME`):
  - prefers a running local Antigravity `language_server_macos*` over loopback
    (`127.0.0.1`) Connect-RPC (`GetUserStatus`, `RetrieveUserQuotaSummary`,
    `GetCommandModelConfigs`), locating listening TCP ports directly via
    Darwin's socket-only `libproc` API without `lsof` or folder access;
  - falls back read-only when installed and not running to the macOS Keychain
    item `gemini` / `antigravity` (via `/usr/bin/security`, unwrapping
    `go-keyring-base64:` and hex blobs) or local `oauth_creds.json` against
    `daily-cloudcode-pa.googleapis.com`; tokens are never refreshed, cached or
    logged.
- **Hidden agents leave the dropdown panel too.** Switching an agent off in the
  panel or in **Settings → Agents** now hides it from both the menu bar and the
  main dropdown panel to save space; re-enable any hidden agent from
  **Settings → Agents**. If every detected agent is switched off, the panel
  offers a direct **Open Settings…** button.

## 1.1.1 — 2026-11-19

- **OpenRouter key with a daily limit** now reads that day's spend
  (`usage_daily`) instead of the month's.
- **OpenRouter history only moves on a clean read.** A failed or partial
  OpenRouter read (whose numbers are filled in from the last good one) no
  longer advances the month-by-month history, so last month's spend can't be
  recorded against a new month.
- **OpenRouter history is kept per scope.** Switching between one key and the
  management key (account-wide), or to another key, starts a new history, so
  one key's spend never becomes the account's average. Histories from 1.1.0
  carry on under whichever mode reads next.

## 1.1.0 — 2026-11-19

- **OpenRouter account-wide with a management key.** Paste an OpenRouter
  management key (from openrouter.ai/settings/management-keys) into
  **Settings → Advanced → OpenRouter** and OpenRouter covers every key on the
  account, not just one inference key:
  - **All keys · this month** — every key's monthly spend as a meter against
    the average of the last N calendar months (*$49.93 of $61.20 avg
    (Sep–Oct)*), from OpenRouter's analytics (queried at most once a month),
    else from the months the app has observed; yellow and the real percent
    when over. **Usage meter** (on/off) and **Average of the last N months**
    (1–12, default 2) sit next to the key in Settings; off means no meter and
    no analytics request;
  - **Credits** — the credits left (*$20.81 left*), with no lifetime totals;
  - the top N keys by spend this month (**Show the top N keys**, default 3,
    0–12): a meter against the key's limit with its reset, or
    *$X.XX this month* for a key without a limit. Unused keys are left out.

  The menu bar shows the credits left (`$20.81`) beside the mark — or this
  month's spend when credits aren't available — and that one monthly meter. **Save** verifies the
  key (*Verified · N keys*, or why not); **Remove** returns to the per-key
  view. `OPENROUTER_MANAGEMENT_KEY` from your login shell works too.
- **Stored only in the Keychain.** The management key lives in your login
  Keychain (`com.crueber.agentic-apple.openrouter-management-key`), never in
  settings, the cache, logs or CLI output, and is never shown again after
  saving. The item is created by `/usr/bin/security` (key on stdin), so reading
  it never prompts, and it is read once per launch. **If you tested an early
  1.1.0 build and macOS keeps asking for the key, click Remove, then Save the
  key once.** A failing management key is reported (for example *Management key
  expired or invalid*) and the last numbers are kept; the app does not quietly
  fall back to the inference key.
- Without a management key, OpenRouter behaves exactly as before.

## 1.0.2 — 2026-11-18

- **Grok shows both meters.** With only Grok Bot in use, Grok now shows the
  plan's **Weekly limit** meter (empty, since only the Grok CLI reports it)
  beside **Grok Bot weekly**, instead of the Bot meter alone.
- **Reliable relaunch after an update.** The updated app is now started
  directly through LaunchServices as a new instance, which waits for the old
  copy to quit before taking over; the shell helper is only a fallback. 1.0.1
  could install an update and then not come back.
- **Update log.** The updater records each step in
  `~/Library/Logs/The Agentic Apple/update.log`, so a failed update or relaunch
  can be diagnosed.

> Updating **from 1.0.1** to 1.0.2 still uses 1.0.1's relaunch, so if the app
> does not come back after this one update, open it once; later updates use the
> new relaunch.

## 1.0.1 — 2026-11-18

- **Grok Bot without the Grok CLI.** Grok now appears when only the Grok Bot
  desktop app is in use: its cached weekly allowance is shown with the plan
  label from the Bot's own reading. Before, the Grok Bot meter was only read
  when a Grok CLI snapshot existed, so Bot-only users saw no Grok at all.
- Grok Bot's macOS cache location
  (`~/Library/Application Support/Grok Bot/sand-client-persistence`) is now
  confirmed against a real install.

## 1.0.0 — 2026-11-17

General availability.

The Agentic Apple is now considered stable: the meters, the panel, settings,
launch at login and signed automatic updates make up the supported 1.x feature
set, and the settings keys, CLI flags (`--text`, `--json`) and cache locations
are stable across 1.x releases.

- First release delivered by the app's own updater: installed copies of 0.2.0
  update themselves to 1.0.0.
- Releases build on GitHub's `macos-latest` runners.

> **Coming from 0.1.0?** Install 1.0.0 by hand once (0.1.0 has no updater);
> later releases arrive on their own.

## 0.2.0 — 2026-11-17

Signed automatic updates.

> **Coming from 0.1.0?** 0.1.0 has no updater. Install 0.2.0 by hand once
> (download the DMG and drag it over the old copy, or `git pull &&
> scripts/install.sh`); every later release then arrives on its own.

- **Automatic updates from GitHub Releases.** The app checks for a new release
  about 2 minutes after launch and then every 6 hours. A newer version is
  downloaded, verified and installed, and the app relaunches into it.
- **Every update is verified before it is installed:**
  - the disk image must carry an Ed25519 signature (`.dmg.sig`) from a key
    listed in the app itself (`UpdateKeys.swift`); there is no way to add a
    key or change the feed at run time;
  - the app inside the image must have the same bundle ID
    (`com.crueber.agentic-apple`) and a strictly newer version than the
    running copy, so an older signed release cannot be replayed.
- **Installs only where it is safe:** the updater replaces an installed copy in
  a writable Applications folder (`/Applications` or `~/Applications`). A copy
  run from the disk image, from `dist/`, through `swift run` or the CLI is
  never touched.
- **Swap with rollback:** the new app is staged beside the old one, the old
  one is moved aside as a backup, and if anything fails the backup is put
  back. The app then relaunches, and the new version removes the backup.
- Downloads are HTTPS only from `github.com` / `*.githubusercontent.com`
  (other redirects are refused) and capped at 64 MB for the disk image.
- **Install updates automatically** setting (`autoUpdate`, on by default).
  When it is off, nothing is checked in the background; **Check for
  Updates…** in the menu still checks by hand.
- Releases are now signed in CI (`scripts/sign-update.swift`) and the
  signature is verified against the committed trusted keys before anything is
  published; the DMG and its `.sig` are uploaded together.
- `scripts/generate-update-key.sh` sets up the signing key once.

## 0.1.0 — 2026-11-17

First release: a native macOS port of the Omarchy plugin
[Agent Meters](https://github.com/crueber/omarchy-plugin-agent-meters) 1.1.1.

- One menu bar item for OpenRouter, OpenCode, Grok, Codex and Claude, each
  with its own monochrome mark and up to three limit meters. Three bar styles:
  meters, short percentages, or marks only.
- Automatic selection: an agent appears only when it has a plan, a key or
  usage on this Mac.
- A panel with every limit window, reset countdowns, local activity,
  OpenRouter credits and previous-cycle comparison, and OpenCode Console
  budgets; per-agent show switches and drag-to-reorder.
- All five sources are native Swift; no Node and no Omarchy collectors:
  - **Claude** reads Claude Code's OAuth sign-in read-only (Keychain via
    `/usr/bin/security`, or `~/.claude/.credentials.json`) and calls Anthropic's
    usage endpoint, ported from Omarchy's Claude collector. Session, weekly and
    model-scoped windows (such as Fable weekly). An expired sign-in shows
    *Sign-in expired* or *Limits paused* and keeps the last numbers, marked
    stale. Today's prompts and tokens come from an incremental scan of Claude
    Code's transcripts.
  - **Codex** talks JSON-RPC to a short-lived `codex app-server`, ported from
    Omarchy's Codex collector, including mise-aware binary discovery, plan
    names, code-review and model-scoped windows, and a Business seat's spend
    cap.
  - **OpenCode** uses `opencode api` (with a `--standalone` retry) and reads
    today's activity from its SQLite store read-only.
  - **OpenRouter** keeps the plugin's key lookup, key-limit and dollar modes,
    and six-hour previous-cycle rule.
  - **Grok** reads the billing snapshot and session ledgers under `~/.grok` and
    Grok Bot's cache (macOS Application Support path first). Ported and
    fixture-tested; not yet verified against a live Grok install on macOS.
- Refresh every 5 minutes by default (1 minute to 1 hour), manual refresh at
  most every 30 seconds, back-off from 1 to 10 minutes, refresh on wake. The
  last result is cached and painted at launch; one failing agent keeps its
  last good numbers.
- Login-shell `PATH` discovery for tools installed with Homebrew, mise, npm,
  bun or cargo, with per-tool overrides in Settings.
- Settings window (General, Agents, Thresholds, Advanced, About) over the same
  keys as the Omarchy plugin, in the defaults domain
  `com.crueber.agentic-apple`. Launch at login through `SMAppService`: an
  installed copy turns it on at its first launch and re-registers itself if
  macOS loses the registration, so the app survives restarts; switching it
  off is remembered.
- Command-line modes on the app's executable: `--text`, `--json`,
  `--render-preview <dir>`, `--version`, `--help`; `--fixture` for invented
  data.
- An installable disk image (`scripts/make-dmg.sh`): the app plus an
  Applications shortcut, attached to each GitHub release by the release
  workflow.
- `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/build-app.sh` and
  `scripts/test.sh`: builds with the Command Line Tools alone, ad-hoc signed.
- Offline self-test executable with synthetic fixtures for every agent, run in
  CI on macOS along with the app bundle build.
- README, SECURITY.md, AGENTS.md and a GitHub Pages site; every image is
  composed from invented data.
