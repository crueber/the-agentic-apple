# AGENTS.md

The Agentic Apple — a native macOS menu bar app (Swift, AppKit + SwiftUI) that
shows limit meters for the AI agents a Mac actually uses: OpenRouter, OpenCode,
Grok, Codex and Claude. It is a port of the Omarchy plugin
[Agent Meters](https://github.com/crueber/omarchy-plugin-agent-meters); when in
doubt about behaviour or wording, the reference plugin's `Model.js`,
`collect.js` and `Panel.qml` are the specification. Claude and Codex are ported
from Omarchy's `omarchy-agent-usage-claude` / `omarchy-agent-usage-codex`
(omacom/omarchy), not reconstructed.

## Constraints

- **Command Line Tools only.** No Xcode project, no `xcodebuild`, no XCTest or
  swift-testing. Build with SwiftPM; `scripts/build-app.sh` assembles and
  ad-hoc signs the `.app`. Tests are the `agentic-selftest` executable.
- **No dependencies.** Foundation, AppKit, SwiftUI, ServiceManagement and
  CryptoKit (update signatures) only. The OpenRouter management key's Keychain
  item is handled through `/usr/bin/security`, not the Security framework.
- **macOS 14+**, Swift tools 6.0, language mode 5 for every target.
- **No Node, no Omarchy.** External tools (`opencode`, `codex`, `mise`,
  `sqlite3`, `security`) are only invoked when present.
- **Public repository.** Fixtures and previews are synthetic. Never commit a
  real workspace name, key, account, email or usage figure.

## Layout

- `Package.swift` — targets `AgenticCore` (library), `AgenticApple`
  (executable `agentic-apple`), `AgenticSelfTest` (executable
  `agentic-selftest`).
- `Sources/AgenticCore/` — pure and testable, no AppKit.
  - `Model/Provider.swift` — `ProviderID`, `Limit`, `Activity`, `Money`,
    `Budget`, `Provider`, `CollectorContext`, `ProviderCollector`.
  - `Logic/` — each file's header lists its public API and constants:
    `State` (meter state, windows, OpenRouter window), `Ordering`,
    `OpenRouterHistory` (cycle baseline), `Merge`, `Schedule`, `Format`,
    `Summary` (bar text, tooltip, captions), `Cache`.
  - `Providers/` — one collector per agent, plus `Collector` (runs all five
    concurrently), `Shell` (process runner, `SearchPath`), `HTTP`, `Sanitize`.
    Each provider file's header documents its sources, paths and endpoints.
    `OpenRouterAccount` is OpenRouter's management-key (account-wide) mode.
  - `Update/` — the updater, AppKit-free: `UpdateFeed` (GitHub
    `releases/latest`, asset names, caps, `UpdatePolicy` host allowlist),
    `UpdateDownloader`, `UpdateSignature` (Ed25519), `UpdateVersion`,
    `UpdateInstaller` (verify, mount, stage, swap, cleanup) and `UpdateKeys`
    (`UpdateKeys.trusted`: base64 public keys, appended to by
    `scripts/generate-update-key.sh`, never changed at run time).
- `Sources/AgenticApple/`
  - `main.swift` — CLI modes first, then the accessory app.
  - `App/` — `CLI` (`--text`, `--json`, `--render-preview`, `--fixture`),
    `AppDelegate` (single instance, wake, About), `Store` (fetch lifecycle,
    cache, order/switch writes), `AppSettings` (UserDefaults keys),
    `ManagementKeyStore` (thin wrapper over Core's `KeychainTool` and
    `ManagementKeyMemo`: save/remove the OpenRouter management key; never reads
    the secret back),
    `AppInfo` (name, bundle id, defaults domain, cache URL), `LoginItem`.
  - `Bar/` — `StatusItemController` (status item, clicks, keys, menu,
    popover), `BarView`.
  - `Panel/` — `PanelView` (hero, drag-to-reorder, footer, empty state),
    `ProviderSection`, `Controls`, `PanelActions`.
  - `Settings/` — `SettingsView` (General, Agents, Thresholds, Advanced,
    About), `SettingsWindowController`.
  - `Marks/` — traced vector marks (`MarkShapes`, `ProviderMark`, `SVGPath`).
  - `Preview/` — `PreviewFixture` (invented data, fixed clock) and
    `PreviewRenderer` (`--render-preview`).
  - `Shared/` — `DisplayState` (everything the bar and panel draw), `Palette`,
    `InlineCode`.
- `Sources/AgenticSelfTest/` — `Harness.swift` (`TestRun`, `Fixtures`), one
  suite per file, registered in `main.swift`.
- `Tests/Fixtures/<agent>/` — synthetic fixtures, including a fake Codex
  app-server script.
- `scripts/` — `build-app.sh`, `make-dmg.sh`, `install.sh`, `uninstall.sh`,
  `test.sh`; `generate-update-key.sh` (one-time signing-key setup, run by the
  maintainer: private key to `~/.config/the-agentic-apple/update-signing-key`
  and the `UPDATE_SIGNING_KEY` Actions secret, public key into
  `UpdateKeys.swift`); `sign-update.swift` (`sign`, `check`, `verify`; run with
  `swift scripts/sign-update.swift …`, key only from the environment).
  `.github/workflows/release.yml` builds, signs, verifies and publishes the
  DMG and its `.sig` on a `v*` tag.
- `docs/` — the GitHub Pages site; `docs/images/` comes from
  `--render-preview`.

## Normalised shape

Every collector returns a `Provider`:
`{ id, name, available, tier, status, hint, error, source, limits[{ key, label,
short, percent, resetsAt, limited, stale }], activity{ period, prompts, tokens },
money?, budgets[], readAt }`. `percent` is 0–100, `resetsAt` and `readAt` are
epoch milliseconds (0 = unknown). OpenRouter's window is derived from `money`
and the cycle history in `Logic/State.swift`; with an inference key its
`limits` stay empty. With a management key, `money.label` is
`Money.accountWideLabel` ("All keys", Σ `usage_monthly`, no limit) and
`money.baseline` (`MonthlyBaseline`, from `/api/v1/analytics/meta` +
`POST /api/v1/analytics/query`, at most once a month — `AnalyticsMemo` in the
run, `CollectorContext.openrouterBaseline` from the cache across launches) is
the previous two months' average; without it `Meters.accountBaseline` averages
`CycleHistory.previous`/`older`. The month window is a meter against that
baseline (percent may exceed 100; yellow when over), the bar draws credits
left plus that one meter. `HTTPClient.post` exists only for analytics.
`limits` holds `credits` (a value row: `Limit.amount` = credits left), then
up to 12 `key-<hash8>` rows ranked by `usage_monthly` (zero left out; a limited
key is a meter, an unlimited one a value row with `amount` = monthly spend).
`Meters.windowsFor(..., keyRows:)` puts the money window first, then those
limits, keeping the first `openrouterKeyRows` keys (UI only, no refetch). The
bar shows only `Meters.barDollarsText` (credits left, else monthly spend).
`Limit.amount` (optional, nil for every other provider) marks a value row.

## Data sources

| Provider | Source |
| --- | --- |
| OpenRouter | Management key first: `OPENROUTER_MANAGEMENT_KEY` → Keychain `com.crueber.agentic-apple.openrouter-management-key` / `default` via `/usr/bin/security … -w` (once per process); then `GET /api/v1/keys?offset=N` (≤ 10 pages of 100) and `/api/v1/credits`, no fallback on failure; at most monthly `GET /api/v1/analytics/meta` + `POST /api/v1/analytics/query` for the two-month baseline. Otherwise `OPENROUTER_API_KEY` → `authFile` / `OPENROUTER_AUTH_FILE` → `$XDG_DATA_HOME` or `~/.local/share/opencode/auth.json` → `opencode auth export [openrouter]`; then `GET /api/v1/key`, `/api/v1/credits` |
| OpenCode | `opencode api GET /api/experimental/usage/limits`, retry `opencode api --standalone GET …`; activity from `opencode.db` via `/usr/bin/sqlite3 -readonly -json` |
| Grok | last `billing: fetched credits config` line of `~/.grok/logs/unified.jsonl`; `sessions/*/*/usage.json`; Grok Bot `*.blob` under `~/Library/Application Support/Grok Bot/sand-client-persistence`, then `~/.config/Grok Bot/…` (Grok Bot alone is enough: no CLI snapshot → Bot meter only, tier from `grokPlanLabel`) |
| Codex | `codex -s read-only -a on-request app-server`: `initialize` → `initialized` → `account/rateLimits/read` (`rateLimitsByLimitId`, else legacy `rateLimits`), `account/read` only for the plan |
| Claude | Keychain `Claude Code-credentials` via `/usr/bin/security … -w`, and `~/.claude/.credentials.json` (later `expiresAt` wins); `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`; activity from `~/.claude/projects/**/*.jsonl` |

Claude windows: `five_hour` → `session`, `seven_day` → `weekly`, the `limits`
array's model-scoped entries and legacy non-null `seven_day_<model>` buckets →
one row per model (key = model slug, plus the window when it is not weekly).
Utilisation is already a percentage. Rank: session, weekly, model-scoped,
monthly, other.

Codex windows: general buckets map to `session` / `weekly` / `review` /
`spend` / `monthly`; a non-general bucket carries its name in `title`
(`o3 Weekly`) and maps to a `scoped-` key ranked after every general window.

## Invariants

1. **Credentials are read-only and transient.** Never refresh, write back,
   cache, log, print or pass on a command line any key or token. OpenRouter's
   key and Claude's token travel only in an HTTPS `Authorization` header.
   Codex's token is never read at all — only `auth_mode` and key presence.
   The single exception to "read-only" is the OpenRouter management key the
   user pastes into Settings: `KeychainTool` has `/usr/bin/security -i` create
   the login-Keychain item with the key on **stdin** (never argv; the key is
   limited to `[A-Za-z0-9-_.~+/=:]` so it is one `security -i` token), so
   `security` owns it and its reads never prompt. The collector reads it once
   per process through `security … -w` (`ManagementKeyMemo`; injectable
   `managementKeyReader` / `KeychainTool.Runner`), and it never reaches
   UserDefaults, the cache, logs, argv, errors, CLI output or the `Provider`.
   It is not a settings key. Never create that item with `SecItemAdd`: an
   app-created item is bound to the ad-hoc signature and prompts on every read.
2. **`available` decides the bar.** Set it only for a plan, limits, a tier or
   a detected key. An agent with nothing stays out; never draw an empty shell.
3. **Collectors never throw.** Failures become `error` (and `hint`); the
   merge (`ProviderMerge`) keeps the last good numbers and adds the error.
   Claude's *Sign-in expired* / *Limits paused* keep the old limits, marked
   `stale`.
4. **Everything from outside goes through `Sanitize`.** Strings via
   `Sanitize.plain` before display, numbers via `Sanitize.number`, dates via
   `Sanitize.dateMs`; files are size-checked before reading; `UsageCache.slim`
   re-sanitises on write and read.
5. **Bounded everything.** Processes run through `Shell.run` (no shell string,
   timeout, capped output); usage HTTP through `HTTPClient` (HTTPS, no
   redirects, 15 s, 1 MB). Update downloads go through `UpdateDownloader`
   (HTTPS, redirects only to `UpdatePolicy.isAllowedDownloadURL` — github.com
   and *.githubusercontent.com — 64 MB DMG / 4 KB signature caps). The updater's
   tools (`hdiutil`, `codesign`, `ditto`) also run through `Shell.run`; the
   only shell string is the fixed `/bin/sh` relaunch helper.
6. **Never tint marks.** Marks use the inherited foreground; only meters and
   percentages carry `MeterState` colours. Colour rules live in
   `Meters` (`Logic/State.swift`): critical ≥ `criticalPercent` or `limited`,
   warning ≥ `warnPercent`, OpenRouter yellow when over the previous cycle.
7. **OpenRouter history** keeps one current and up to two completed cycles
   (`previous`, `older`); a cycle is kept only when observed within six hours
   of its end. The per-key view uses `previous` only.
8. **Order and visibility.** `providerOrder` is a comma-separated id string;
   missing ids follow in `ProviderID.defaultOrder`. `DisplayState.panelProviders`
   is every available agent in that order (so a hidden one can be switched back
   on); `barProviders` filters by `show<Agent>`. Drops go through
   `Ordering.reorderInsert`, which keeps hidden agents in place.
9. **Settings keys match the reference plugin** (`barStyle`, `show<Agent>`,
   `providerOrder`, `refreshIntervalSec`, `warnPercent`, `criticalPercent`,
   `warningColor`, `criticalColor`, `showActivity`, `opencodeCommand`,
   `codexCommand`, `grokHome`, `botHome`, `authFile`). Do not rename them.
   `autoUpdate` (bool, default true) and `openrouterKeyRows` (int 0–12,
   default 3) are this app's own additions.
   `launchAtLogin` mirrors `SMAppService` and records the user's choice:
   `LoginItem.ensureOnLaunch` turns it on at an installed copy's first launch
   and re-registers when the setting is on but macOS lost the item; never from
   a DMG, translocated or `dist/` path. `--unregister-login-item` removes it
   (used by `scripts/uninstall.sh`).
10. **One defaults domain.** `AppInfo.defaults` makes `swift run` and the CLI
    read `com.crueber.agentic-apple`, the same domain as the bundled app.
11. **Schedule** (`Logic/Schedule.swift`): automatic every
    `refreshIntervalSec` (60–3600, default 300) with a 60 s floor, manual at
    most every 30 s, back-off 1 → 2 → 4 → 8 → 10 min only when every available
    agent fails or the 90 s collection timeout fires. The cache is written after
    every attempt and painted on launch.
12. **GUI environment.** The app inherits launchd's environment, not the
    shell's. `SearchPath.resolveEnvironment` probes the login shell once per
    launch (own session, no controlling terminal, bounded by a timeout) for
    `PATH` and the allowlist in `SearchPath.importedVariables`; a variable
    already in the process environment wins. A new variable a collector reads
    belongs in that allowlist. The Store races the probe against 10 s and falls
    back to the process environment plus well-known directories.
13. **Processes never outlive their timeout.** `Shell.run` and the Codex RPC
    client spawn children in their own process group and signal the group;
    output draining after exit is bounded, so a grandchild holding a pipe
    cannot stall a refresh. The one exception is the update relaunch helper,
    which must outlive the app it replaces — and it is only a fallback: the
    updater relaunches through `NSWorkspace.openApplication`
    (`createsNewApplicationInstance`, the old PID in
    `AGENTIC_APPLE_RELAUNCH_AFTER`), and the new instance waits for that PID
    before its single-instance check. Updater steps go to
    `~/Library/Logs/The Agentic Apple/update.log` (`UpdateLog`) — never secrets.
14. **Updates are signed or not installed.** Never install anything whose
    `.dmg.sig` does not verify (Ed25519, over the raw DMG bytes) against a key
    in `UpdateKeys.trusted`, and never mount or read the image before it does.
    The app inside must have bundle ID `com.crueber.agentic-apple` and a
    version strictly newer than the running one (replay defence). There is no
    runtime override of the key list or the release feed — no setting,
    variable, file or argument. Install only into an installed copy in a
    writable Applications folder; never from the CLI modes, `swift run`, an
    unbundled or `dist/`/DMG/translocated copy, or the self-tests (tests use
    injected HTTP and temporary directories, never the network or a real
    bundle). Swap with a backup and roll back on any failure; the new version
    removes the staging copy and the backup at launch
    (`UpdateInstaller.cleanupLeftovers`).

## Testing

```bash
scripts/test.sh                       # all suites, offline
scripts/test.sh Codex                 # one suite (substring match on the name)
SCRATCH_PATH=.build-mine scripts/test.sh   # own build directory when others are building
swift run agentic-apple --fixture --text
swift run agentic-apple --fixture --json
swift run agentic-apple --render-preview /tmp/previews
scripts/build-app.sh                  # dist/The Agentic Apple.app
```

Tests must stay offline and deterministic: point `CollectorContext.home` at
`Fixtures.tempHome(_:)`, inject `CollectorContext.http`, use
`Fixtures.fakeBinary(in:name:script:)` for external tools, inject the Claude
Keychain reader and OpenRouter's `managementKeyReader` (every
`OpenRouterCollector(...)` in a test passes one), and pass a fixed `now`. Never touch the real Keychain, network
or home directory. Do not run live `--text` / `--json` during development: it
probes real credentials and raises the Keychain prompt; leave live checks to
the user.

Cache: `~/Library/Caches/com.crueber.agentic-apple/{usage,claude-activity}.json`;
neither may ever contain key material or text.

## Adding a provider

1. `ProviderID` case, `displayName`, `defaultOrder` (`Model/Provider.swift`).
2. `Providers/<Name>.swift` conforming to `ProviderCollector`, following the
   invariants above; any new path or variable gets a Settings override.
3. Register it in `Collector.all` and `Collector.live`.
4. Mark: path in `Marks/MarkShapes.swift`, both switches in
   `Marks/ProviderMark.swift`.
5. `PanelEmptyState.paths` (`Panel/PanelView.swift`); optionally
   `Preview/PreviewFixture.swift`.
6. A self-test suite + fixtures under `Tests/Fixtures/<id>/`, registered in
   `Sources/AgenticSelfTest/main.swift`.
7. README (What you get, Automatic selection, Each agent in detail, How it
   fetches, Troubleshooting), SECURITY.md (reads, processes, network) and this
   file.

`show<Id>`, ordering, the Agents settings pane and the CLI follow from
`ProviderID.allCases`.

## Releasing

One-time: the maintainer runs `scripts/generate-update-key.sh` and commits
`Sources/AgenticCore/Update/UpdateKeys.swift`. Never run it, read the private
key or set secrets on the user's behalf.

1. Bump `VERSION` and add a `## X.Y.Z — YYYY-MM-DD` section to
   `CHANGELOG.md` (the release notes are taken from it).
2. Commit and push to `main`.
3. Tag `vX.Y.Z` (must equal `VERSION`) and push the tag.

`release.yml` fails early if the tag and `VERSION` differ, the
`UPDATE_SIGNING_KEY` secret is empty, or `UpdateKeys.trusted` is empty or lacks
the secret's public key; then self-tests, builds, signs, verifies against the
committed keys and publishes the DMG and `.sig` in one `gh release create`.
Key rotation is two-phase: `generate-update-key.sh --rotate` stages a new key
(`…/update-signing-key.next`) and appends its public key while the secret keeps
the old one; release once (the bridge trusts both, signed with the old key);
then `--activate` switches the secret. Drop the old public key only after every
copy has updated past the bridge (see SECURITY.md).
