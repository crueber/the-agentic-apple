# The Agentic Apple — build plan

A native macOS menu bar app that reproduces
[omarchy-plugin-agent-meters](https://github.com/crueber/omarchy-plugin-agent-meters):
one status item showing each AI agent's mark and limit meters, and a panel with
the full breakdown, switches and drag-to-reorder.

## Constraints found during orientation

- macOS 26.6 (arm64), Swift 6.3 **Command Line Tools only** — no Xcode, so no
  `xcodebuild`, no XCTest / swift-testing. Build with SwiftPM and assemble the
  `.app` bundle with a script. Tests are an executable target
  (`swift run agentic-selftest`) with a tiny assertion harness.
- The reference leans on Omarchy collectors (`omarchy-agent-usage-claude`,
  `omarchy-agent-usage-codex`) that do not exist on macOS. We implement those
  sources natively.
- Node is not assumed: all collectors are Swift. External tools (`opencode`,
  `codex`) are only *invoked* when present.

## Decisions after orientation + advisor review

- **Port, don't reconstruct.** Claude and Codex sources are ported from
  Omarchy's own collectors (`omacom/omarchy` `bin/omarchy-agent-usage-claude`,
  `bin/omarchy-agent-usage-codex`), not guessed.
- **Confirmed live:** `opencode api GET /api/experimental/usage/limits` →
  `data.go.{rolling,weekly,monthly}.{percent,limited,resetsAt(ms)}`,
  `data.budgets[]`, `data.workspace.{name,…}`.
- **Codex:** `codex -s read-only -a on-request app-server`, JSON-RPC lines:
  `initialize` → `initialized` notification → `account/rateLimits/read`
  (`rateLimitsByLimitId`, legacy `rateLimits`). Binary discovery must handle
  mise shims (this machine's shim has no version set) like Omarchy's
  `find_codex_binary`. No rollout files exist here, so no rollout fallback is
  relied upon.
- **GUI PATH:** a login-launched app does not inherit the shell PATH. Resolve
  once via `$SHELL -l -c 'printf %s "$PATH"'` (with a timeout), merge with
  `~/.local/bin`, `/opt/homebrew/bin`, mise shims/installs; per-tool path
  overrides in Settings.
- **Claude credentials are read-only.** Keychain via `/usr/bin/security
  find-generic-password -s "Claude Code-credentials" -w` first (stable ACL
  across ad-hoc rebuilds), `~/.claude/.credentials.json` second, the one with
  the later `expiresAt` wins. **Never refresh the token** — an expired token
  shows *Sign-in expired* with the `claude auth login` hint. Model-scoped
  windows are mapped generically (`seven_day_<model>`, `*_scoped`).
- **Live check by the user:** the app has `--json` / `--text` CLI modes; the
  user runs them once to confirm live shapes (credential probes are not run
  during development).
- **Fixtures are synthetic.** Public repo: no real workspace names, keys,
  accounts or figures anywhere.
- **Grok** isn't installed here; Grok support is ported and fixture-tested only
  (README says so). Grok Bot macOS cache path:
  `~/Library/Application Support/Grok Bot/sand-client-persistence`.
- **Builds during fan-out:** each subagent uses its own
  `--scratch-path .build-<name>`; one suite file per agent in the self-test.
- **Bar width:** compact by default (notched displays).

## Architecture

```
Package.swift            (macOS 14+, Swift 6 language mode 5 for pragmatism)
Sources/
  AgenticCore/           pure, testable — no AppKit
    Model/               Provider, Limit, Money, Budget, Activity, Window, State
    Logic/               state math, ordering/visibility, OpenRouter cycle history,
                         formatting (percent, currency, counts, "Resets in 4d 0h"),
                         tooltip/compact text, cache (de)serialisation, backoff
    Providers/           one file per agent, all → Provider
      Sanitize.swift, Process.swift (run with timeout, bounded output),
      HTTP.swift (URLSession, timeout, 1 MB cap)
      OpenRouter.swift   key from OPENROUTER_API_KEY | ~/.local/share/opencode/auth.json
                         | `opencode auth export`; GET /api/v1/key, /api/v1/credits
      OpenCode.swift     `opencode api GET /api/experimental/usage/limits`
                         (retry `--standalone`); today's activity from local store
      Grok.swift         ~/.grok/logs/unified.jsonl billing snapshot, session
                         usage.json ledgers, Grok Bot blob cache
                         (~/Library/Application Support/Grok Bot/…)
      Codex.swift        `codex app-server` JSON-RPC: initialize →
                         account/rateLimits/read; fallback: newest
                         ~/.codex/sessions/**/rollout-*.jsonl `rate_limits`
                         (fully local)
      Claude.swift       OAuth token from Keychain item
                         "Claude Code-credentials" (fallback
                         ~/.claude/.credentials.json); GET
                         https://api.anthropic.com/api/oauth/usage
                         (five_hour, seven_day, seven_day_<model>…);
                         activity from ~/.claude/projects/**/*.jsonl today
      Collector.swift    runs all five concurrently, merges with last good
                         result per provider (a failure keeps old numbers + error)
  AgenticApple/          AppKit + SwiftUI app
    App.swift            NSApplication, LSUIElement, AppDelegate
    StatusItem.swift     NSStatusItem hosting a SwiftUI bar view (marks + mini
                         meters / text / icon styles); left click panel,
                         right click menu (Refresh, Settings, Quit)
    Panel/               NSPopover: hero (count, updated, highest %, refresh),
                         provider sections (mark, tier, activity line, limit rows
                         with meter + reset countdown, OpenRouter money, OpenCode
                         budgets), show switches, drag-to-reorder with insertion
                         line, footer
    Marks/               the five monochrome marks as SwiftUI `Shape`s, ported
                         from the QML vectors
    Settings/            SwiftUI Settings window: bar style, per-agent show,
                         interval, thresholds, colours, command paths, launch at
                         login (SMAppService)
    Store.swift          @Observable app state; refresh scheduler (default 5 min,
                         manual ≥30 s apart, failures back off 1→10 min); cache
                         at ~/Library/Caches/com.crueber.agentic-apple/usage.json
                         (0700 dir), painted on launch
  AgenticSelfTest/       executable test runner (fixtures + fake binaries)
scripts/
  build-app.sh           swift build -c release → The Agentic Apple.app
                         (Info.plist, icon, ad-hoc codesign)
  install.sh             build + copy to ~/Applications + optional login item
  test.sh                swift run agentic-selftest
  make-preview.sh        renders synthetic-data preview PNGs (app's
                         `--render-preview` mode via ImageRenderer)
docs/                    GitHub Pages static site (index.html, style, images)
.github/workflows/ci.yml macOS runner: build + self-test
README.md, LICENSE (MIT), SECURITY.md, CHANGELOG.md, AGENTS.md
```

Same normalised shape as the reference collector:
`{ id, name, available, tier, status, hint, error, source, limits[{key,label,short,percent,resetsAt,stale}], activity, money, budgets }`.

Behaviour carried over 1:1: automatic selection (agents with no plan/key/usage
stay out), default order OpenRouter → OpenCode → Grok → Codex → Claude with a
saved order winning and new agents appended, per-agent show switches, colour
rules (critical ≥90 or source-limited, warn ≥70, OpenRouter yellow when over
previous cycle, otherwise foreground), marks never tinted, OpenRouter
previous-cycle baseline, Claude "Sign-in expired" state, Grok Bot stale reading.

macOS-native extras: launch at login, a `agentic-apple` CLI mode
(`--text`, `--json`) for scripts, dark/light menu bar aware drawing.

## Execution with subagents

1. **Me:** scaffold package, core model types, sanitize/process/HTTP helpers,
   `Provider` contract, build script — the shared seams everything else uses.
2. **Parallel subagents** (worktree-free, disjoint files):
   - A: OpenRouter + OpenCode providers + fixtures/tests
   - B: Grok + Codex providers + fixtures/tests
   - C: Claude provider + Collector + Logic (state, order, history, format,
     cache) + tests
   - D: Marks (port QML paths to SwiftUI Shapes) + bar view
3. **Me / one subagent:** Panel UI, Store, Settings, status item wiring.
4. Build, self-test, run the app, screenshot with synthetic data.
5. **Parallel:** README, GH Pages site (docs/ + enable Pages), CI workflow.
6. Code review subagent pass, fix, commit, push.
