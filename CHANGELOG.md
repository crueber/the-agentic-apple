# Changelog

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
