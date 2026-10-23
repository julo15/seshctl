# Seshctl

## Build & Test

- **SwiftPM lock contention:** SwiftPM acquires a file lock on `.build/`. If a second `swift build` or `swift test` runs concurrently, it blocks indefinitely. Always use a **timeout of 120s** for builds and **30s** for test runs. If a build/test hangs or times out, immediately run `make kill-build` before retrying.
- `make kill-build` — force-kills all stale SwiftPM processes
- `make install` — canonical dev loop: build + sign + install `Seshctl.app` to `/Applications` and re-launch. AppDelegate's launch-time reconciler refreshes the CLI symlink, standalone uninstaller, and hook registrations automatically.
- `make uninstall` — one-liner: runs `seshctl uninstall` against the installed CLI (CLI symlink + hook entries + standalone uninstaller + marker + Codex `[features].hooks` flag). Drag `Seshctl.app` to Trash separately.
- `make cert-setup` — one-time: generate the self-signed code-signing identity in the login keychain.
- `make test` — run all tests
- **Hook-only changes and `make install`:** the launch-time reconciler refreshes `~/.local/share/seshctl/hooks/` only when the version changes or `Contents/MacOS/SeshctlApp` is newer than the install marker. A change that touches only `hooks/**/*.sh` doesn't relink the binary, so `make install` leaves the old hooks in place. `touch /Applications/Seshctl.app/Contents/MacOS/SeshctlApp` and relaunch to force a refresh. (Releases are unaffected — the version bump triggers it.)

## Distributable App Build (Phase 1)

Seshctl ships as a self-signed `.app` bundle in a DMG. There is exactly one install surface — the bundled app — and two ways to produce it:

- **Dev iteration:** `make install` → build + sign + drop `Seshctl.app` into `/Applications` + re-launch. Fast rebuild loop.
- **Release artifact:** `make dist` (= `bundle → sign → make-dmg`) → `dist/Seshctl-<VERSION>.dmg`. See [`docs/release.md`](docs/release.md) for the full release flow.

**Bundle metadata is in `Resources/Info.plist`** — that's the source of truth. `CFBundleShortVersionString` drives the DMG filename. Don't hard-code versions elsewhere.

**Code signing:** `Seshctl Self-Signed` in the user's login keychain. Set up via `make cert-setup` (one-time). The public cert PEM is committed at `Resources/seshctl-self-signed-public.pem`. See [`docs/signing.md`](docs/signing.md) for cert lifecycle, .p12 backup, and the future Developer ID upgrade.

**Install/uninstall logic** lives in `Sources/SeshctlCore/FirstLaunchInstaller.swift`. `AppDelegate` is the canonical install orchestrator: every `.app` launch reads the install marker, compares bundle path / version / executable mtime against the running bundle, and silently calls `FirstLaunchInstaller.install(bundleURL:)` on any mismatch — no welcome panel for upgrades, just refresh. End-user upgrades (drag a new DMG over the old one) and `make install` both flow through this single path. Never duplicate the logic in bash again.

**Make targets:**
| Target | What |
|---|---|
| `make bundle` | Assemble `dist/Seshctl.app` from SwiftPM build (no signing) |
| `make icon` | Regenerate `Resources/AppIcon.icns` from `AppIcon.svg` (needs `rsvg-convert`) |
| `make sign` | Sign `dist/Seshctl.app` with the self-signed cert |
| `make make-dmg` | Create `dist/Seshctl-<VERSION>.dmg` |
| `make dist` | Full pipeline: `bundle → sign → make-dmg` |
| `make appcast` | EdDSA-sign the DMG and regenerate `docs/appcast.xml` for Sparkle (see Sparkle Auto-Updates section) |
| `make publish` | `publish-docs → publish-release`: commits + pushes metadata, waits for Pages, creates GitHub Release |
| `make publish-docs` | Stage 1 of publish: commit Info.plist + appcast + release notes, push, poll Pages |
| `make publish-release` | Stage 2 of publish: `gh release create` with the DMG (re-runnable on its own if upload fails midway) |
| `make install` | `bundle → sign`, then replace `/Applications/Seshctl.app` and re-launch (canonical dev loop) |
| `make install-vscode` | Build + install VS Code extension |
| `make install-cursor` | Build + install Cursor extension (chat-thread focus + terminal-tab focus) |
| `make cert-setup` | One-time: generate the self-signed cert in login keychain |
| `make uninstall` | One-liner: invokes `seshctl uninstall` (CLI symlink + hooks + standalone uninstaller + marker + Codex `[features].hooks` flag) |

**Phase 2 (Sparkle auto-updates) is implemented.** See `Sparkle Auto-Updates` section below for the runtime, key, and release-flow details. The plan is `.agents/plans/2026-05-20-2300-sparkle-auto-updates.md`.

## Sparkle Auto-Updates (Phase 2)

Seshctl ships Sparkle 2.x so DMG users get one-click upgrades. The app fetches an appcast on launch + every 24h, presents Sparkle's standard prompt when a newer version is advertised, and swaps `/Applications/Seshctl.app` in place after EdDSA signature verification.

**Bundle wiring.** `Sources/SeshctlApp/AppDelegate.swift` owns one `SPUStandardUpdaterController`, constructed early in `applicationDidFinishLaunching` (after first-launch reconcile, before silent extension refresh) with `startingUpdater: true`. The framework is pulled in as a SwiftPM dependency attached to `SeshctlApp` only — `SeshctlCore` stays Foundation-only. Three Info.plist keys configure it: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks=true`.

**Feed URL.** `https://julo15.github.io/seshctl/appcast.xml`, served by GitHub Pages from `docs/appcast.xml` on `main` (one-time Pages enablement: Settings → Pages → main branch, `/docs` folder). The appcast is the full version history regenerated by `make appcast` on every release.

**`SettingsPopover → About → Check for Updates…`** drives `SPUStandardUpdaterController.checkForUpdates(_:)` on demand. Plumbed through the same `onCheckForUpdates: (() -> Void)?` closure pattern used by `onUninstall` / `onOpenIntegrations`: `AppDelegate → RootView → SessionListView → SettingsPopover`.

**EdDSA signing key.** Generated once on each release host via `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. Private key lives in the login Keychain (item `https://sparkle-project.org`); base64 export is backed up to 1Password ("Seshctl Sparkle EdDSA private key" secure note) mirroring the `.p12` pattern. Public key is committed in `Resources/Info.plist` as `SUPublicEDKey`. **Losing the private key without the 1Password backup orphans every existing install** — see the public-key-rotation procedure in `docs/signing.md`.

**Release pipeline.** Three make commands: `make dist` (unchanged) produces the signed DMG; `make appcast` mirrors the DMG into `dist/releases/` (gitignored), optionally renders `docs/release-notes/<VERSION>.md` for the appcast `<description>`, and runs Sparkle's `generate_appcast` to emit `docs/appcast.xml`; `make publish` chains `publish-docs` (commit + push the metadata, poll Pages until the new appcast is live) and `publish-release` (`gh release create v<VERSION>` with the DMG asset). `publish-docs` is idempotent and `publish-release` is independently re-runnable, so a failed mid-flight DMG upload doesn't require redoing the docs push. The full flow lives in [`docs/release.md`](docs/release.md).

**Important invariants:**
- `CFBundleVersion` must strictly increase per release. Sparkle compares this integer (not `CFBundleShortVersionString`) to decide whether a new version is available.
- The `dist/releases/` mirror is the source of truth for `generate_appcast`. If you delete a DMG from it, Sparkle's appcast drops that version. Keep historical DMGs for delta-update generation.
- `make appcast` is NOT chained into `make dist`. Keeps dist testable without a populated mirror.
- Sparkle's EdDSA signature is independent of Apple's code signature, so Phase 1B (notarization) can land later without disturbing Sparkle.

### Where things live

| Component | File / Path | Notes |
|---|---|---|
| Sparkle SwiftPM dep | `Package.swift` | Attached to `SeshctlApp` target only |
| Updater init | `Sources/SeshctlApp/AppDelegate.swift` | `updaterController` stored property + `checkForUpdates()` method |
| Closure plumbing | `SessionListView.swift`, `SettingsPopover.swift` | `onCheckForUpdates: (() -> Void)?` |
| Feed URL + key | `Resources/Info.plist` | `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` |
| Appcast | `docs/appcast.xml` | Regenerated by `make appcast`; served by GitHub Pages |
| Release notes per version | `docs/release-notes/<VERSION>.md` | Markdown; consumed by both `make appcast` and `gh release create` |
| Build mirror | `dist/releases/` | Gitignored; `make appcast` populates from `dist/Seshctl-<VERSION>.dmg` |
| Sparkle tools | `.build/artifacts/sparkle/Sparkle/bin/` | `generate_keys`, `sign_update`, `generate_appcast` |
| Private key | Login Keychain item `https://sparkle-project.org` | 1Password backup mandatory |
| Public-key rotation procedure | `docs/signing.md` | What to do if the private key is lost |

## Test Coverage

When adding or modifying logic in `Sources/`, run tests with coverage and verify your changes are covered:

```bash
swift test --enable-code-coverage   # ~7s, outputs coverage JSON
swift test --show-codecov-path      # prints path to the JSON
```

Extract coverage for project files (not dependencies) with:
```bash
jq '[.data[0].files[] | select(.filename | contains("/Sources/")) | {file: (.filename | split("/Sources/")[1]), pct: (.summary.lines.percent * 100 | round / 100)}]' "$(swift test --show-codecov-path)"
```

**Rules:**
- New logic (view models, database methods, parsers) must have tests. View-only files (SwiftUI views) are exempt.
- If you add a public method to a file that already has tests, add a test for the new method.
- Check coverage of files you modified — if a file drops below 60% line coverage after your changes, add tests to bring it back up.

## Adding Terminal App Support

Seshctl supports multiple terminal apps. The architecture enforces a single code path for all session actions (focus, resume, clipboard fallback) through three key files:

- **`Sources/SeshctlCore/TerminalApp.swift`** — Registry enum. Single source of truth for bundle IDs, display names, URI schemes, and capabilities. Every `switch` is exhaustive (no `default` cases) — adding a new case triggers compiler errors everywhere it needs handling.
- **`Sources/SeshctlUI/TerminalController.swift`** — Execution engine. Handles both focusing existing tabs and resuming sessions in new tabs. All terminal interaction goes through here.
- **`Sources/SeshctlUI/SessionAction.swift`** — Routing entry point. All user actions (Enter on any row type) go through `SessionAction.execute()`. Never add focus/resume logic to AppDelegate or views.

### How detection works

When `seshctl-cli start` runs, `detectHostApp()` in `Sources/seshctl-cli/SeshctlCLI.swift` walks the process tree from the shell PID upward, looking for a GUI app via `NSRunningApplication`. The bundle ID and name are stored in the database alongside the session. No per-app code is needed here — any app that launches a shell process is detected automatically.

One edge case: cmux embeds libghostty and sets `TERM_PROGRAM=ghostty` in the shells it spawns, so matching on `TERM_PROGRAM` alone would misroute cmux sessions to Ghostty. `TerminalApp.from(environment:)` handles this by checking `$CMUX_WORKSPACE_ID` / `$CMUX_SOCKET_PATH` first and only falling back to `TERM_PROGRAM` when neither is present.

### How focusing and resuming works

When the user presses Enter on any row, `SessionAction.execute()` determines the action (focus vs resume), resolves the target app via a single chain (DB → PID walk → frontmost terminal), and dispatches to `TerminalController`.

**Pattern 1: AppleScript focus** (Terminal.app, iTerm2, Ghostty, Warp, cmux) — `supportsAppleScriptFocus` capability

`open -b` brings the app forward, then AppleScript iterates windows/tabs matching by TTY path (Terminal.app, iTerm2, Ghostty), DB-assisted tab matching (Warp), or workspace + surface UUIDs (cmux — `$CMUX_WORKSPACE_ID` and `$CMUX_SURFACE_ID` are captured by the session-start hook and packed into `windowId` as `"<workspace>|<surface>"`). For cmux, the outer loop matches `id of tab` against the workspace UUID and a nested loop then `focus`es the `terminal` whose `id` matches the surface UUID, so both levels of cmux's hierarchy (vertical workspace list, horizontal tab within) are raised.

**Ghostty — TTY match ladder.** `buildFocusScript` emits three rungs: TTY → legacy terminal ID → working directory. Ghostty's scripting dictionary (`/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`) exposes `tty`, `pid`, and a `focus` command on the `terminal` class, plus a flat `terminals` element on `application`. `tty` is unique per *surface*, so it disambiguates both split panes sharing a tab and tabs sharing a working directory — the common case when several agents run in one repo. `focus` targets the surface, so it raises the window, selects the tab AND focuses the split; the directory rung's `select tab` + `activate window` only manages the first two.

The TTY is derived from the recorded PID at focus time via `SystemEnvironment.tty(for:)` — it needs no stored state and self-heals across resume, since a resumed session fires a fresh hook with a new PID. **But `tty` only exists in main-channel Ghostty builds; stable 1.3.1's dictionary lacks it**, so on stable the TTY rung always throws and falls through. That's why the session-start hooks still capture the terminal ID (`focused terminal of selected tab of front window`) — it's the only precise rung on stable. The capture has known flaws (assumes the starting session is frontmost, costs an Automation prompt, goes stale after resume), so drop it from both `hooks/claude/session-start.sh` and `hooks/codex/session-start.sh` once a stable Ghostty release exposes `tty`.

Rungs 1-2 are each wrapped in `try` because `tty` and `focus` are absent from older Ghostty dictionaries, and an unknown term aborts the entire script — taking the directory fallback down with it. Don't unwrap them. The `version` property is useless for gating: main-channel builds report a bare git hash (`07d31666e`), not a semver.

**cmux fork — CLI dispatch via Unix socket** (separate from the AppleScript focus path above)

`SessionAction.forkSession` for cmux sessions routes through `TerminalController.forkCmuxAdjacent`, which drives cmux's bundled CLI (`<cmux.app>/Contents/Resources/bin/cmux`) over the Unix socket at `~/Library/Application Support/cmux/cmux.sock`. The dispatch chain is `tree --json --workspace <ws>` (find the source surface's pane id) → `new-surface --pane <pane>` → `tree --json` again (diff before/after to recover the new surface UUID) → `send --workspace <ws> --surface <new> -- <payload>`. Subprocess waits run on `DispatchQueue.global()` via `TerminalController.forkExecutor` with a 3-second per-call timeout so a wedged daemon never blocks the @MainActor panel.

**cmux socket auth — required user-side opt-in for fork to work.** cmux defaults `automation.socketControlMode` to `cmuxOnly`, which gates the socket on process ancestry: only descendants of the cmux GUI process are honored. SeshctlApp launched from the Dock, `make install`, or a LaunchAgent has `launchd` (PID 1) as its ancestor — never cmux — so every CLI invocation returns `Failed to write to socket (Broken pipe, errno 32)` and `forkCmuxAdjacent` falls through to the `resume()` new-workspace path. To enable in-pane fork the user must set `automation.socketControlMode` to `"automation"` (socket stays `0600`, ancestry check disabled — the recommended mode) or `"allowAll"` (socket becomes `0666`, anyone in the user session can connect — looser, only choose with the trade-off in mind) in `~/.config/cmux/cmux.json` and restart cmux. The README `cmux setup` section is the user-facing copy; mirror any changes between the two. There is no daemon-side code-signature check or per-bundle-id allowlist — auth is purely (process ancestry → cmuxOnly) OR (password → password mode) OR (nothing → allowAll/automation), so no entitlement or signing trick on the SeshctlApp side can bypass `cmuxOnly`.

**Pattern 2: URI handler** (VS Code, VS Code Insiders, Cursor) — `supportsURIHandler` capability

`open -b` brings the app forward, then a URI handler (e.g. `vscode://julo15.seshctl/focus-terminal?pid=<pid>`) triggers the companion extension.

**Pattern 3: Generic AppleScript fallback** (unknown apps)

System Events script searches window names for the session's directory name and raises the matching window.

### How to add a new terminal app

1. **Add a case to the `TerminalApp` enum** in `TerminalApp.swift` — the compiler will show you every place that needs a handler (bundle ID, display name, URI scheme, capabilities)
2. **Add focus/resume AppleScript** in `TerminalController.buildFocusScript()` and/or `buildResumeScript()` if the app uses AppleScript
3. **(Optional) Add a same-pane fork dispatch** in `TerminalController.fork(...)` if the app exposes a CLI or AppleScript verb for opening a sibling surface in the existing pane (analogous to cmux's `forkCmuxAdjacent`). Without this, fork falls through to the new-window/new-tab `resume(...)` path, which is fine but loses the same-pane affordance.
4. **Add tests** in `Tests/SeshctlUITests/TerminalControllerTests.swift` for script generation and focus routing — and `ForkRoutingTests` for any fork-dispatch addition
5. **Build a companion extension** (only if using the URI handler pattern)

**Rules:**
- All bundle IDs and URI schemes live in `TerminalApp` — never hardcode them elsewhere
- All user actions go through `SessionAction.execute()` — never add focus/resume logic to AppDelegate or views
- All terminal interaction goes through `TerminalController` — never call `open -b` or `osascript` directly
- The CLI, hooks, and database are app-agnostic — no changes needed there
- Apps that reuse another terminal's env vars (like cmux setting `TERM_PROGRAM=ghostty` because it embeds libghostty) need an explicit higher-priority check in `TerminalApp.from(environment:)` so detection doesn't misroute to the shadowed app

### Security note

All strings interpolated into AppleScript (TTY paths, directory names) must go through `TerminalController.escapeForAppleScript()` to prevent injection. This escapes backslashes, quotes, and strips control characters. Any new AppleScript generation must use this function.

## Adding an LLM Tool

Seshctl ingests session state from each LLM CLI/IDE via shell hooks. New tools plug in through `SessionTool` (a `CaseIterable` enum) plus a `hooks/<tool>/` script bundle plus a `HookSpec` entry in `FirstLaunchInstaller`. Existing integrations: Claude Code, Codex, Cursor.

Surfaces to touch when adding a new tool:

- **`Sources/SeshctlCore/Session.swift`** — `SessionTool` enum. Add a case with a stable raw string. The compiler will flag every exhaustive `switch` that needs an update.
- **`Sources/SeshctlCore/TranscriptParser.swift`** — per-tool transcript directory / parser. Return `nil` for MVP if the transcript format is undocumented.
- **Row title** — `SessionListViewModel.refresh()` switches over `SessionTool` to fill `titlesById`: Claude reads its transcript (`TranscriptTitleScanner`), Codex its thread-name index (`CodexThreadNameIndex`). Add a case for the new tool's title source, or leave it untitled (the row falls back to branch, then folder).
- **`Sources/SeshctlUI/AgentBadgeSpec.swift`** — per-tool glyph + color for the row badge.
- **`Sources/SeshctlUI/Session+Display.swift`** — per-tool display name.
- **`Sources/SeshctlUI/TerminalController.swift`** — per-tool resume binary + verb (or fall through to focus-only if there's no `<tool> <session>` CLI).
- **`Sources/seshctl-cli/SeshctlCLI.swift`** — `--tool` help strings list the valid values.
- **`hooks/<tool>/*.sh`** — script bundle invoked by the tool's hook system. Each script reads JSON from stdin and shells out to `seshctl-cli start/update/end`. Mirror `hooks/codex/` as the template. Use `--conversation-id <id>` as the upsert key when the tool's PID is unstable across hook events (Cursor's case — each hook is a fresh `/bin/zsh -c` subprocess).
- **`Sources/SeshctlCore/FirstLaunchInstaller.swift`** — add a `HookSpec` (`<tool>ScriptNames` + `<tool>Entries(for:)`) and wire it into `install()` / `uninstall()` / `resolveHookSourceDirs(bundleURL:)`. Different tools have different hooks.json schemas (Claude/Codex share one; Cursor uses its own `{ "version": 1, "hooks": { ... } }` shape), so each tool needs its own inject/remove helpers.
- **`Sources/SeshctlCore/Database.swift`** — if your tool's hook subprocess PID is unstable across events (Cursor 1.7+ has this property), you'll need conversation-id-keyed Database overloads. The trio in `Database.swift` — `findActiveSession(conversationId:tool:)`, `updateSession(conversationId:tool:...)`, `endSession(conversationId:tool:status:)` — mirrors the pid-keyed methods; mirror them again or extend them.
- **`scripts/build-app-bundle.sh`** — copy `hooks/<tool>/` into `Contents/Resources/hooks/<tool>/` so the bundled `.app` ships with the scripts.
- **`README.md`** — add a row to the "LLM tools" compatibility table.
- **Tests** — `Tests/SeshctlCoreTests/FirstLaunchInstallerTests.swift` mirrors per-tool install/uninstall idempotency; add equivalent coverage for the new tool. Any `CaseIterable`-driven tests (display name, badge spec) get the new case automatically.
- **`Sources/SeshctlRecall/Adapters/<Tool>Adapter.swift`** — new transcript adapter conforming to `Adapter`. Cursor shape is per-tool (Claude uses per-file `{offset, cwd}`; Codex uses single `{offset}`; Gemini uses `{seen: [[s, m]]}` dedup set).
- **`Sources/SeshctlRecall/AdapterRegistry.swift`** — add the new adapter to `defaultAdapters()`.
- **`Sources/SeshctlRecall/RecallService.swift`** — extend the `resumeCommand(for:)` switch in `RecallStack` with the new agent's resume CLI shape.

**Rules:**
- All hook event names, JSON shapes, and script paths live in `FirstLaunchInstaller` and `hooks/<tool>/` — never hardcode them in the CLI or app code.
- The CLI and Database are tool-agnostic except for the `SessionTool` raw string. Don't branch on `tool` in `seshctl-cli` unless it's genuinely tool-specific (e.g. the Cursor lazy-create path in `Update`/`End` keyed on `--conversation-id`).
- Exhaustive `switch`es over `SessionTool` are the safety net: never add `default:` cases.

### Codex gates hooks behind a trust prompt

Codex (verified against codex-cli 0.145.0) will not run a hook until the user has trusted it. On the next launch after seshctl installs or changes its hooks, Codex shows a **Hooks need review** screen — `Trust all and continue` / `Review hooks` / `Continue without trusting (hooks won't run)` — and until the user accepts, Codex sessions silently never reach seshctl. There is a `--dangerously-bypass-hook-trust` flag; don't reach for it on the user's behalf.

Trust is content-sensitive: Codex distinguishes `New hook - review required` from `Modified since last trusted - review required`. `writeHookScripts` rewrites every deployed script on every install, so **any change to `hookGuardBlock` re-triggers the prompt for every Codex user**, not just changes to `hooks/codex/*.sh`. Budget for that when touching the guard.

Codex's event set is PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, SessionStart, SessionEnd, SubagentStart, SubagentStop, Stop, UserPromptSubmit. seshctl registers SessionStart, UserPromptSubmit, Stop, and SessionEnd.

**Codex's `$PPID` is not the session's process.** Codex's app-server mode (0.163+, `source: vscode` in the rollout's `session_meta`) runs hooks from a long-lived worker under `codex app-server daemon`, so the PID the hooks record is that shared worker, not the per-session `codex` process. While the worker lives, the stale reaper can't end the session; `SessionEnd` is what ends it. When the worker dies the daemon never reaps it, so it lingers as a zombie, and `kill(pid, 0)` reports zombies as alive. All liveness checks go through `ProcessLiveness.isAlive`, which treats zombies as dead. Use it rather than a bare `kill(pid, 0)`. `x` on an active row with no live process ends the row (`stale`) rather than sending a SIGTERM that can't land.

## Claude Hook Status Transitions

The local session status comes entirely from `hooks/claude/*.sh`:

| Event | Script | Status |
|---|---|---|
| `UserPromptSubmit` | `user-prompt.sh` | working |
| `PreToolUse` | `pre-tool-use.sh` | working; **waiting** for `AskUserQuestion` / `ExitPlanMode` |
| `PostToolUse` (matcher `AskUserQuestion\|ExitPlanMode`) | `post-tool-use.sh` | working (the user answered) |
| `Notification` | `notification.sh` | waiting (permission prompts, idle prompts) |
| `Stop` | `stop.sh` | idle |
| `SessionEnd` | `session-end.sh` | ended |

**Subagent tool calls share the parent's session and PID.** Their hook payloads carry `agent_id` (absent on the main session's calls), and `hooks.log` tags them `agent=<id>`. Left unchecked, a background subagent's next tool call flips a session waiting on an open question back to working. `pre-tool-use.sh` guards this with a per-session marker at `~/.local/share/seshctl/state/claude-awaiting-user-<session_id>`: blocking tools create it, and while it exists, subagent calls make no update. `post-tool-use.sh`, `stop.sh`, `user-prompt.sh`, `session-end.sh`, and the main session's next tool call all clear it. Subagent calls still set working when no marker exists. That's what un-sticks a session after the user approves a *subagent's* permission prompt (which goes through `notification.sh` and never creates a marker).

**Debugging a wrong dot:** `grep <session_id> ~/.local/share/seshctl/logs/hooks.log` shows the event sequence. Hook updates run in the background (`&`), so two events in the same second can land in either order.

## Row Order

Rows sort newest-first, but only when the panel opens. `panelDidShow()` snapshots every row's recency rank into `frozenOrder`, and `sortedForDisplay(_:)` — the one sort behind `activeRows`, `recentRows` and the tree groups — keeps that order until `panelDidHide()` clears it. Without this, every hook update jumped a row to the top and moved the click target out from under the cursor. Rows the snapshot hasn't seen in their current active/recent state (a new session, or one that just resumed) go on top. Route any new row sort through `sortedForDisplay`, not a bare `sortTimestamp` sort.

**Pinned panels.** A pinned (keep-open) panel never hides, so show/hide alone would freeze its order forever. The freeze therefore follows *use*, not visibility: `FloatingPanel.isInUse` is true while the panel is focused or under the mouse, and `AppDelegate` forwards every change (`onInteractionChange`, fired from `becomeKey`/`resignKey`/`mouseEntered`/`mouseExited`) to `SessionListViewModel.setOrderFrozen(_:)`. A pinned panel sitting unfocused and unhovered re-sorts live like a dashboard; hovering or focusing it snapshots the order it's showing, so nothing moves before the click lands. Hover counts because a pinned panel is usually clicked without being focused first. A transient panel is in use for as long as it's shown, so its behaviour is unchanged.

## Status Dots

`StatusKind` (`Sources/SeshctlUI/StatusKind.swift`) is the single source of truth for the row's status dot: color, animation (`isPulsing` for working, `isPinging` for waiting), `isHollow` (completed/offline), and age dimming via `color(age:)` (neutral gray kinds fade for yesterday / older). Both `SessionRowView` and `RemoteClaudeCodeRowView` render it through `AnimatedStatusDot`, passing the row's `SessionAgeDisplay.bucket`. Don't hardcode dot colors in a row view.

The palette follows the activity-monitor convention: green = the agent is running, amber = blocked on the user (the loudest treatment), gray = not running. Two SwiftUI traps in `AnimatedStatusDot`:
- **`repeatForever` animations can't be cancelled by resetting state.** The animated body is keyed with `.id(kind)` so a status change rebuilds it; without that, a session that went working → idle kept pulsing in gray.
- **`drawingGroup()` rasterizes into the view's bounds.** The fixed 40pt frame must fit the largest effect (the working halo), or kinds without a halo clip to an 8×8 square. The frame doesn't affect layout — `ResultRowLayout` hosts the dot as an overlay.

## Bridged Sessions (local CLI <-> claude.ai)

A CLI session started with `/remote-control` exists on both sides. `BridgeMatcher` pairs them so the list shows one row, not two, and the row exposes both halves: **Enter** focuses the terminal, **w** (or clicking the row's `cloud.fill` glyph) opens claude.ai.

**The join key comes out of the transcript, and its shape has changed once already.** `TranscriptBridgeScanner` recognizes two record shapes:

- **Current:** `{"type":"bridge-session","sessionId":"<local uuid>","bridgeSessionId":"cse_<SUFFIX>"}` — the API id verbatim.
- **Legacy:** `{"type":"system","subtype":"bridge_status","url":"https://claude.ai/code/session_<SUFFIX>"}` — id derived from the web URL.

Last matching record in the file wins. When Claude Code stopped writing the legacy shape, the scanner silently returned `nil` for every transcript and every bridged pair split back into two unlinked rows — no error, no log, just a quiet regression. **If pairing ever "stops working" again, grep a live transcript for `bridge` first** (`grep -n 'bridge' ~/.claude/projects/<slug>/<convId>.jsonl`) before touching `BridgeMatcher`; the matcher is deterministic and rarely the culprit.

**Both shapes are supported indefinitely, not transitionally.** Transcripts on disk are never rewritten, so a `.jsonl` written before the CLI changed keeps the legacy shape forever and stays resolvable as long as it's on disk. Don't plan on retiring the legacy branch or its fixtures — treat the `switch` in `TranscriptBridgeScanner` as append-only, one case per shape Claude Code has ever emitted.

**Where the pairing surfaces.** `SessionListViewModel.refresh()` publishes three projections of the same `BridgeMatcher` output: `bridgedLocalIds` (row renders the cloud glyph), `bridgedRemoteIds` (twin filtered out of `activeRows`/`recentRows`), and `bridgedRemoteIdByLocalId` (the full map, used by `bridgedRemote(for:)` / `selectedWebUrl` to resolve the web URL for the `w` action). Keep the three in sync — the tests in `SessionListViewModelTests` assert the map's keys and values equal the two id sets.

**Local vs. web routing.** `w` goes through `AppDelegate.openSelectedOnWeb` -> `vm.selectedWebUrl` -> `SessionAction.execute(target: .openRemote(...))` — the same action Enter uses on a pure-remote row, so browser tab reuse via `RemoteBrowserCoordinator` is shared. The mouse path (`SessionRowView.onOpenWeb`, plumbed `AppDelegate -> RootView -> SessionListView`/`SessionTreeView`) dispatches the same target. Never add a second browser-opening path.

**Claude desktop app first, browser second.** `SessionAction.openRemote` checks `env.appBundleURL(forBundleId: ClaudeDesktopApp.bundleId)` before touching the browser stack. When the Claude desktop app is installed, it derives `claude://code/session_<SUFFIX>` from the web URL via `ClaudeDesktopApp.sessionURL(fromWebURL:)` and opens it through `env.openURL`; the app switches its single window to that session (to a local twin if it runs one, otherwise its in-app remote viewer), so nothing piles up. When the app isn't installed, or the URL doesn't carry a valid session id, it falls through to `RemoteBrowserCoordinator` / `BrowserController` unchanged. On a bridged CLI row, `w` therefore opens the desktop app's remote viewer — the desktop app has no local twin for a terminal session. **The deep link is undocumented** (found in `Claude.app/Contents/Resources/app.asar`, verified on desktop 3.1623.4), and `open` reports success even when the app ignores a route, so a breaking desktop update can't be detected at runtime. Keep the browser path as the fallback; never delete it.

**`ClaudeDesktopApp` (`Sources/SeshctlCore/ClaudeDesktopApp.swift`)** is the registry for the desktop app: bundle ID, URL scheme, and the deep-link builders. It's neither a `TerminalApp` nor a `BrowserApp`. Every id goes through `isValidSessionId` — the desktop app's own `^(cse|session)_[A-Za-z0-9_-]+$` — before it's interpolated into a URL, since ids come from an API response. `SessionAction.openRemote` derives the link from the session's claude.ai web URL via `sessionURL(fromWebURL:)`, so it always sends the `session_…` form; the desktop app accepts both `session_…` and `cse_…`.

**Remote-row recaps page through reconnect noise.** Pure-remote rows get their message from `RemoteClaudeCodeFetcher.fetchLatestAssistantText`, which reads `/v1/code/sessions/<id>/events` newest-first. Remote-control sessions write a ~9 KB `system/init` event on every reconnect, so the newest pages are often nothing but those — with a single `limit=10` page, every remote row went blank with no error. The fetcher now pages back via `?cursor=<next_cursor>` (the only paging param the endpoint honors; it ignores every event-type filter we tried) up to `maxEventPages` (5). Idle sessions can bury their last reply hundreds of events deep (measured 34–830+, up to ~9 MB), so those stay blank by design rather than paying that download. **If remote recaps go blank again,** run `log stream --level debug --predicate 'subsystem == "app.seshctl" AND category == "remote-fetcher"'` and relaunch — each fetch logs how many pages it walked and how it ended.

For how `bridgedLocalIds` fits alongside the other transcript-derived row signals (caching, pruning, the scanner pattern), see "Transcript-Derived Row Signals" below.

## Closed-Sessions View (`c`)

`c` swaps the live list for closed sessions (`SessionListViewModel.isRecentsMode`, rows from `closedRows`). Enter reopens through the normal `.inactiveSession` resume path; there is no separate restore action. Rules:

- **Source:** `Database.listRecentSessions`, not `listSessions(limit: 50)`. It dedupes to the newest row per conversation at read time (nothing is deleted), hides conversations that are running again, and has its own limit. `recentSessions` is loaded only while the mode is on.
- **Overrides, doesn't mutate:** `filteredRows` checks `isRecentsMode` before tree mode and search. Tree mode is suspended without writing the persisted `isTreeMode`, so `v` and the group-jump keys no-op in `c`.
- **Ordering is plain recency,** not `sortedForDisplay`: the frozen order only snapshots the newest 50 `sessions`.
- **Reset on every panel show** (`AppDelegate.showPanel`), and Esc/`q` leave the mode before they close the panel.

## Title Suggestions (`t`)

`t` asks Claude Haiku for a title describing what the selected session is doing **now**; `y` saves it, `n` or Esc declines it. Claude Code's `ai-title` is written once from the opening prompt, so a long session keeps a title for its first task — this is the user-initiated fix. There's no automatic titling.

- **Recency-biased material** (`TitleSuggester.prompt`): the last 10 requests the user typed and the last 3 assistant replies, with an instruction to title only the current task and name the work rather than workflow steps (commit, PR, merge). The tail of a session is mostly "yes" and "merge", so feeding just the last few turns titles whatever the final reply discussed.
- **Left out on purpose:** the current title (given Claude's stale `ai-title` as background, Haiku kept naming the session's first task) and `user` records the user didn't type: skill bodies, task notifications, image paths (`TitleSuggester.nonTypedPrefixes`). In a real session those filled half the 10-request window.
- **One suggestion, confirmed.** A run takes ~3.5s with stdin closed (`ShellRunner` passes `/dev/null`; an inherited stdin makes `claude -p` wait 3s first), and a bad title is declined with `n` and retried with `t`. `y`/`n` reuse the kill/fork confirm keys and only act when nothing else is pending.
- **Stored per conversation** in `conversation_titles` (`conversation_id` + `tool`), not on the session row: every resume creates a new row, and a per-row title would vanish on the next reopen. In `refresh()` a picked title overrides the tool's own (Claude's `ai-title`, Codex's thread name) on every row of that conversation.
- **The run stays out of the user's history.** `claude -p --model haiku --setting-sources project --no-session-persistence`, from a fresh empty temp directory per run (removed afterwards): no user settings means seshctl's own hooks don't fire, so the run never becomes a row, and nothing lands in `~/.claude/projects` or `/resume`. Don't switch to `--bare`: it skips hooks too, but only accepts `ANTHROPIC_API_KEY`, not a subscription login.
- **The run can only write text.** `--tools ""` and `--strict-mcp-config`: the prompt quotes transcript text, which could ask the model to read files or call tools.
- **Needs the `claude` CLI, even for Codex rows.** `TitleSuggester.resolveClaudeCLI` checks four fixed paths, since a GUI app's PATH doesn't have it. When none exists the row says so (`TitleSuggestionFailure.cliNotFound`) rather than offering a retry. Failed runs log to `log stream --predicate 'subsystem == "app.seshctl" AND category == "titler"'`.
- `generate` blocks, so `requestTitleSuggestion()` runs it in a detached task; the row shows "Titling…" (`TitleSuggestionView`) and the user can keep navigating. Each request carries a token, and a result for a request that was declined (and maybe asked again) is dropped. Tests swap `titleSuggestionGenerator`.

## Transcript-Derived Row Signals

Five row signals are derived by scanning the live JSONL transcript on each ~2s refresh: `bridgedLocalIds` (via `TranscriptBridgeScanner` → `transcriptBridgeCache`), `awaySummariesById` (via `TranscriptAwaySummaryScanner` → `transcriptAwaySummaryCache`), `latestAssistantById` (via `TranscriptLatestAssistantScanner` → `transcriptLatestAssistantCache`), `titlesById` (via `TranscriptTitleScanner` → `transcriptTitleCache` for Claude; Codex titles come from a separate index, see below), and `modelsById` (via `TranscriptModelScanner` → `transcriptModelCache`). All five live in `SessionListViewModel.refresh()`.

**Session titles.** `titlesById` feeds the row headline. The title comes from Claude Code's own `{"type":"ai-title","aiTitle":…}` record — a short LLM label generated once from the opening prompt and never updated — with `{"type":"custom-title","customTitle":…}` as the fallback. AI title deliberately wins over custom title: custom titles are often remote-control names like `m5: assistant` that identify the machine, not the work. That's the Claude source; Codex rows get theirs from Codex's thread-name index (next paragraph). A title the user accepted with `t` (stored in `conversation_titles`) beats both tools' own — see "Title Suggestions (`t`)" above.

**Model pill.** `modelsById` feeds a small pill just left of the host-app icon, in every layout (`ResultRowLayout.modelPill`). It's the only one of these signals that reads **Codex** transcripts (Codex titles read Codex's index, not its rollout): Claude records `message.model` on each `assistant` record, Codex records `payload.model` on each `turn_context`, and the scanner walks newest-first and stops at the first match. Codex rows use the stored rollout path as-is (the Claude path resolver doesn't apply). Cloud rows take their pill from `RemoteClaudeCodeSession.model`. The pill turns amber when a row's model differs from the most common one for its agent (`usualModelByTool`), so the odd one out stands out in a list that's mostly one model. `TranscriptModelScanner.displayName(for:)` shortens raw ids (`claude-opus-5-5` → `Opus 5.5`) and passes unknown ids through unchanged.

**Codex titles don't come from the transcript.** Codex never writes a title into its rollout. It appends `{"id":<conversation id>,"thread_name":…}` lines to one shared `session_index.jsonl` in its home directory: first the truncated prompt, then the LLM-generated name, then any rename. So the last line per id wins. `CodexThreadNameIndex` reads it incrementally from a byte offset, and `codexThreadNameCache` holds one state per index rather than one per session. The home directory is derived from the rollout path (`<home>/sessions/YYYY/MM/DD/rollout-….jsonl`), because the app can't see `$CODEX_HOME` and users do relocate it. Codex also mirrors the name into `threads.name` in `state_<N>.sqlite`; don't read that, since the schema version is in the filename.

**Row layouts.** `AppearanceDefaults.rowLayoutKey` selects `RowLayout.compact` (default), `.stacked` or `.twoColumn` from Settings → Appearance. Compact is one line per row — headline (`Session.compactHeadline(title:)`: title → branch → folder), the checkout folder (`Session.folderLabel`, worktrees collapsed to their checkout) in the repo accent color, and the message truncated at the row's end. The picker replaced the `seshctl.stackedRowLayout` boolean; `AppearanceDefaults.migrateRowLayout()` runs at launch, carries a saved `false` over as `.twoColumn`, gives everyone else compact, and deletes the old key. Stacked and two-column are slated for removal once compact settles — removing them also removes the layout duplication between the two row views. The keyboard-selected row (`isSelected`, threaded from `viewModel.selectedRow`) expands the message onto up to three lines; hover never expands, because rows resizing under the cursor move the click target. `isSelected` is passed from each list's `index == selectedIndex` — never computed per row from `viewModel.selectedRow`, which rebuilds the whole row list on every access. In stacked/two-column, the title replaces the branch on line 2 and wraps. Both `SessionRowView` and `RemoteClaudeCodeRowView` implement every layout — keep them in step.

For what `bridgedLocalIds` means and how `TranscriptBridgeScanner` derives it (join key shape, legacy fallback, the three published projections), see "Bridged Sessions" above.

**Pattern.** A pure-Foundation scanner in `SeshctlCore` returns an optional value per transcript path. `SessionListViewModel` caches results per resolved path, populates a published `[session.id: X]` map, and prunes cache entries for transcripts whose owning session is no longer live on each refresh. The row view consumes the published map by `session.id` lookup.

**Never decode a whole transcript per refresh.** Live transcripts reach 15 MB+ and change on every turn, and `refresh()` runs on the main thread every ~2s — a forward pass decoding every line cost ~150 ms per scanner per change, which made the panel visibly lag. Pick by signal shape:
- **Newest-decisive-record signals** (away summary, latest assistant text): walk lines newest-first with `TranscriptReverseReader` and stop at the first line that decides the answer. Equivalent to the forward state machine (its final state is set by the newest line that changes it), typically touches only the last few KB, and needs no state beyond the existing mtime cache. Express the scanner as one per-line `step` function returning `.stop(value)` / `.skip`, shared by the file path and the string-in test path.
- **Last-record-wins markers that may sit anywhere in the file** (titles): resume from a byte offset (`TranscriptTitleScanner.State`) and read only appended bytes; first scans draw from a per-refresh byte budget (`titleScanBytesPerRefresh`) so a cold cache fills over a few ticks instead of stalling one. `CodexThreadNameIndex.State` uses the same offset idiom for Codex's shared index, without a budget: the index holds one short line per naming event, not a transcript. Its cache is keyed per index file and replaced each refresh with the indexes still in use, rather than pruned by path.
- The bridge scanner still does a full read per mtime change; its record is written once at `/remote-control` start, so a reverse walk wouldn't stop early — port it to the offset idiom if it ever shows up in profiles.

**Resolve the path through `TranscriptParser.resolveExistingTranscript(for:)`, never `session.transcriptPath` directly.** The stored `transcript_path` is whatever value Claude Code last sent in a hook payload, and Claude re-derives that path from the session's *current* cwd on every event — so when the user `cd`s mid-session (most commonly: into `.claude/worktrees/<name>`), the stored path points at a directory Claude never created. The actual file stays at the cwd-at-session-start location and is uniquely named by conversation id. `resolveExistingTranscript` walks `session.transcriptPath` → computed Claude path → `~/.claude/projects/*/<convId>.jsonl` glob, returning the first one that exists. The cache-prune step in `refresh()` must collect `livePaths` from resolved URLs, not raw `transcriptPath` — otherwise the cache evicts live entries every refresh (the cache keys on the resolved path).

**Asymmetry with `TranscriptParser`.** `TranscriptParser` emits every `system/away_summary` record as an `awaySummary` turn (historical context for the detail view). `TranscriptAwaySummaryScanner` suppresses recaps once the conversation resumes — the scanner returns `nil` when a user/assistant turn lands after the latest recap, because the row preview shows "current state" not history. Don't unify the two: if the row scanner started emitting historical recaps, rows would pin to a 3+-minute-old summary while the user is actively chatting — the bug the stale-recap invalidation rule was added to fix. `TranscriptLatestAssistantScanner` follows the same "current state" framing: it returns `nil` when a *fresh-prompt* `user` event lands after the latest assistant text (string content or array with text/image/etc. — the row falls through to `lastAsk` so the pending prompt shows as `You: …`), but a *tool_result-only* user event does NOT clear the pending text (Claude is still mid-turn, the human didn't do anything — the row keeps showing the latest narration until the next text block lands), and it also returns `nil` when the newest assistant turn is purely `thinking`/`tool_use` (no walk-back to older text-bearing turns — older text is stale once a newer turn has fired).

**Consumer-side collapse for the recap slot.** `awaySummariesById` and `latestAssistantById` both feed the row's `awaySummary:` slot via a single `??` expression at the row-construction sites in `SessionListView` and `SessionTreeView`: `viewModel.awaySummariesById[id] ?? viewModel.latestAssistantById[id]`. The display chain (`Session+Display.swift previewContent(awaySummary:)`) is unchanged. The two scanners are mutually exclusive in practice: `awaySummariesById[id]` is non-nil only when no user/assistant turn followed the recap, and `latestAssistantById[id]` is non-nil only when an assistant text turn is the most recent non-`away_summary` event. If both ever hold a value simultaneously (theoretical race), `away_summary` wins via `??`, preserving today's behavior.

**To add a new transcript-derived signal:** add a sibling pure-Foundation scanner in `SeshctlCore`, mirror `transcriptAwaySummaryCache` / `cachedAwaySummary(for:)` / `pruneTranscriptAwaySummaryCache(keepingPaths:)` on `SessionListViewModel`, plumb a new `@Published` map keyed by `session.id`, and consume by lookup from the row view. Don't branch on `tool` outside the cached helper — the Claude-only guard sits inside `cachedAwaySummary(for:)` / `cachedLatestAssistant(for:)` so non-Claude tools never hit the filesystem.

## App Icon

`Resources/AppIcon.svg` is the source of truth. `scripts/make-icon.sh` renders it through `rsvg-convert` into a full iconset and runs `iconutil` to produce `Resources/AppIcon.icns`, which **is committed** so `make bundle` works on a machine without librsvg. Regenerate by re-running the script when the SVG changes; never hand-edit the `.icns`.

`Info.plist`'s `CFBundleIconFile` names it and `scripts/build-app-bundle.sh` copies it to `Contents/Resources/`. All three have to agree — the app shipped with no icon at all for a while, which is why Cmd+Tab rendered a blank tile.

The menu bar glyph is drawn programmatically in `AppDelegate.statusBarIcon()` rather than shipped as an asset: the bundle is assembled by a shell script, not Xcode, so there's no asset catalog for a multi-scale image. It's a template image, which keeps **only the alpha channel** — macOS discards the color and re-tints per light/dark menu bar. That constrains the art: the back rows recede via reduced alpha rather than a lighter color, and the status dot is punched out with an even-odd winding rule, because painting it in a background color would render as opaque black.

## Editor Integrations

Seshctl ships a companion VS Code / Cursor extension pre-built inside the app bundle, so DMG users can install it from an in-app onboarding pane without a source checkout. Source-checkout devs can still use `make install-vscode` / `make install-cursor` for fast iteration on the extension itself.

**Bundle layout.** `make bundle` builds the `vscode-extension/` package and copies `seshctl.vsix` plus a `seshctl.vsix.version` sidecar into `Seshctl.app/Contents/Resources/extensions/`. The sidecar holds the bundled extension version as a plain string — runtime never parses the `.vsix` zip just to extract a version. `scripts/build-app-bundle.sh` is the one place that produces both files.

**`Sources/SeshctlCore/ExtensionInstaller.swift`.** The install engine. Public API: `surveyInstalledEditors(bundleURL:)`, `install(editor:bundleURL:)`, `uninstall(editor:)`, `refreshExistingInstalls(bundleURL:)`, `uninstallAllEditorExtensions()`. Two injection seams keep the core AppKit-free and testable: `ExtensionRunner` (wraps `ShellRunner` with subprocess + timeout for invoking editor CLIs) and `AppLocator` (looks up the editor app on disk; the production implementation `NSWorkspaceAppLocator` lives in `SeshctlUI` so `SeshctlCore` stays Foundation-only).

**State model.** Install state is read live from the editor itself via `<cli> --list-extensions --show-versions` — Seshctl does NOT cache install state in its own marker file. This avoids the coherence trap where the user uninstalls the extension from inside VS Code's Extensions sidebar and our marker still claims it's present. The bundled extension version comes from the `.vsix.version` sidecar; the comparison is a plain string match (no semver parsing).

**Silent refresh rule.** `refreshExistingInstalls` only reinstalls editors that ALREADY have `julo15.seshctl` installed at a version different from the bundle's. Editors without the extension are left alone — the user must opt in via the Editor Integrations window. Failures (CLI not found, subprocess timeout) are captured into log lines rather than propagated as throws, so a single broken editor never blocks the others.

**Silent refresh trigger.** `AppDelegate.applicationDidFinishLaunching` calls `refreshEditorExtensionsInBackground()` on every launch, dispatched onto `DispatchQueue.global(qos: .utility)`. Results land in `~/Library/Logs/Seshctl/install.log` through the existing `appendInstallLog` helper used by `FirstLaunchInstaller`.

**UI surfaces.** `IntegrationsView` (SwiftUI) is hosted by `IntegrationsWindowController` (NSWindowController). The window auto-opens from `AppDelegate` after a fresh install (when `didJustInstall == true`). It's also reachable any time from `SettingsPopover → Editor Integrations → Configure…`, threaded `AppDelegate → RootView → SessionListView → SettingsPopover`.

**Uninstall.** All three entry points run `ExtensionInstaller.uninstallAllEditorExtensions()` before `FirstLaunchInstaller.uninstall(...)`:
- **GUI menu / SettingsPopover → Uninstall…** — `AppDelegate.runUninstallFlow` with `NSWorkspaceAppLocator`.
- **`seshctl uninstall` CLI / `make uninstall`** — `Sources/seshctl-cli/Install.swift`'s `Uninstall.run()` with `CanonicalPathsAppLocator` (a Foundation-only locator in `SeshctlCore` that hard-codes `/Applications/<editor>.app` paths). CLI can't use `NSWorkspace` because `SeshctlUI` depends on AppKit. The PATH fallback inside `resolveEditorCLI` covers users who relocated the editor.
- **Standalone `~/.local/bin/seshctl-uninstall`** — shell script with its own probe against the same canonical paths (PATH fallback).

Results land in `~/Library/Logs/Seshctl/install.log` (GUI) or stdout (CLI / shell). Failures are logged and swallowed, never block the rest of teardown. **Keep `scripts/seshctl-uninstall.sh` and `FirstLaunchInstaller.uninstallerScriptContents` in sync** — `testStandaloneScriptParity` in `Tests/SeshctlCoreTests/FirstLaunchInstallerTests.swift` enforces byte-equality.

### How to add a new editor

1. **Add a case to `TerminalApp`** in `Sources/SeshctlCore/TerminalApp.swift`. The compiler will surface every exhaustive switch that needs handling — most importantly `extensionCLIName` (return the per-editor CLI binary name, e.g. `"code-insiders"`).
2. **Extend `TerminalApp.allVSCodeVariants`** if the new editor is a VS Code derivative that shares the same `.vsix`.
3. No changes needed to `ExtensionInstaller` itself — it dispatches purely on `TerminalApp` cases.

**Rules:**
- All bundle IDs and CLI names live in `TerminalApp` — never hardcode them in install code.
- `ExtensionInstaller` is the only place that shells out to editor CLIs for install/list/uninstall. Don't add per-editor branches elsewhere.
- Silent refresh never touches editors that haven't opted in — preserve this invariant if you add new flows.
- Exhaustive `switch`es over `TerminalApp` are the safety net for new variants. Never add `default:` cases.

## Chat Focusing

Cursor is the first LLM tool with a focusable in-app chat surface (the Composer panel). The focus flow for `session.tool == .cursor` is a two-leg sequence dispatched by `TerminalController.focus`:

1. **Leg 1 — workspace focus.** `open -b com.todesktop.230313mzl4w4u92 <workspace>` brings Cursor's existing window for the session's workspace to the front (no duplicates — Cursor reuses the existing window for a given path).
2. **Leg 2 — chat focus.** `cursor://julo15.seshctl/focus-chat?id=<conversation_id>` is routed to our companion extension, which calls `vscode.commands.executeCommand("composer.openComposer", <id>)`. The extension is installed via `make install-cursor`. The same 500ms URI-retry pattern as VS Code's `/focus-terminal` covers the case where Leg 2 fires before Leg 1's window switch has completed.

**Workspace-scope quirk.** `composer.openComposer` is workspace-scoped: it silently no-ops if the target chat doesn't belong to the currently-focused workspace. This is why Leg 1 must precede Leg 2 — otherwise the URI lands on the wrong workspace's extension host and does nothing visible.

**Tab-replacement behavior.** If the target chat is already open as a tab, `openComposer` switches cleanly to it. If the chat is closed/archived, Cursor reopens it by replacing the currently-active tab's slot — the displaced chat is not deleted (it remains in history), but it disappears from the visible tab strip. Acceptable for seshctl's UX (the user clicked the row, they wanted to land on it), but document the behavior in the README so it doesn't surprise.

**Argument shape.** Pass the composerId as a bare string (the UUID — same as our `conversation_id`). The object form `{ type: "local", id }` throws `TypeError: t.startsWith is not a function`. The string form is the only correct surface.

**Graceful degrade.** Without `make install-cursor` (extension absent), Leg 2 silently no-ops and the user gets workspace-level focus only. Same model as VS Code's terminal focus.

**Code paths.** Routing lives in `TerminalController.focusViaURIHandler` — when `tool == .cursor` AND `conversationId` is non-empty, build `/focus-chat?id=<convId>`; otherwise fall through to the standard `/focus-terminal?pid=<pid>`. The terminal-host case (Claude Code running inside Cursor's integrated terminal) uses the `/focus-terminal` path unchanged.

All URI parameters interpolated from session data must be URL-encoded — never trust raw strings from the DB.

## Floating Panel and Keep-Open Mode

The session list lives in `FloatingPanel` (`Sources/SeshctlApp/FloatingPanel.swift`), a non-activating `NSPanel`. By default it behaves like Spotlight: floating level, centered on the active screen at every show, dismissed on resign-key. **Keep panel open** (`AppearanceDefaults.keepPanelOpenKey`) pins it: no dismiss on resign-key, `.normal` level unless **Always in front** is on, dimmed to `unfocusedAlpha` without key focus, and its parked position kept.

**Dock / Cmd+Tab only while pinned.** `Info.plist` keeps `LSUIElement = true` and launch sets `.accessory`, so Seshctl is a menu-bar app by default. `AppDelegate.reconcileKeepOpenMode()` is the only place that changes the activation policy, via `activationPolicy(keepOpen:)`: `.regular` while pinned, `.accessory` otherwise. Never force `.regular` for everyone — a contributor PR once did, and it put a Dock icon on every install. In `.regular` mode the app owns no ordinary window, so `applicationDidBecomeActive` / `applicationShouldHandleReopen` treat activation as "show or focus the panel" — except within `launchActivationGrace` of launch, during a modal, or while another window of ours (Sparkle, Editor Integrations) is visible. Both hooks no-op in `.accessory` mode.

**One show path.** Hotkey, status item, Dock, Cmd+Tab, the keep-open toggle and the launch auto-show all go through `AppDelegate.showPanel()`. Don't add another `makeKeyAndOrderFront` + view-model bookkeeping sequence; extend that one. `toggleWouldHide` is shared with the status item's Show/Hide title.

**Frame.** The panel restores its saved frame before enabling autosave (`setFrameUsingName` then `setFrameAutosaveName`) — the other order can persist the default frame over the user's. `centerOnScreen()` skips re-centering only for a pinned panel with a placement that's still on a connected screen (`keepsPlacement`).

**Reconcile order.** `reconcileKeepOpenMode` applies the panel mode before the activation policy: dropping to `.accessory` can take key focus from the panel, and a panel still flagged keep-open at that moment would stay up unfocused instead of dismissing.

## Browser Tab Focusing

**The browser stack is the fallback.** When the Claude desktop app is installed, `SessionAction.openRemote` opens the undocumented `claude://code/<id>` deep link instead and never reaches the coordinator — see "Claude desktop app first, browser second" under Bridged Sessions. Everything below runs only when the app is absent (or the URL has no valid session id).

Browsers (Chrome / Arc / Safari) are NOT in `TerminalApp` — they don't host shell sessions. They live in a parallel registry/coordinator/controller stack:

- **`Sources/SeshctlCore/BrowserApp.swift`** — registry enum. Single source of truth for browser bundle IDs, display names, and AppleScript application names. Foundation-only (no AppKit). Every `switch` is exhaustive.
- **`Sources/SeshctlCore/ManagedTab.swift`** — `(browser, url)` value type. The `url` is the URL we last set on the tab; this is also the lookup key on the next flip. There is no per-browser tab id — Arc reissues numeric tab ids when a tab is promoted from Little Arc to a real sidebar window, Safari has no tab id at all, and unifying on URL keeps the three browsers' code paths uniform.
- **`Sources/SeshctlUI/BrowserController.swift`** — stateless namespace of AppleScript builders and pure helpers. `buildCombinedFocusScript`, `buildOpenTabScript`, `buildNavigateScript`, `defaultBrowser()`, `probeOrder(env:defaultBrowser:)`.
- **`Sources/SeshctlUI/RemoteBrowserCoordinator.swift`** — `final class` that owns the per-process managed-tab state. Public `openOrFocus(url:environment:)` runs the three-step decision:
  1. **Fast path: navigate-by-URL.** If we have a tracked managed tab, run `buildNavigateScript(browser:oldURL:newURL:)` against its browser. The script walks tabs and matches on the substring of the OLD URL we previously set; on hit it sets the new URL on the matched tab. On hit → update tracked URL. On miss → clear tracking and fall through.
  2. **Fallback: focus probe.** Build a single combined AppleScript across all running supported browsers (default-first). Each browser block walks tabs and matches on the substring of the new URL. On hit → focus, no tracking change.
  3. **Open new tab.** Run `buildOpenTabScript` in the user's default browser; it returns the sentinel `"<browser>:ok"` on success. Parse via `RemoteBrowserCoordinator.parseOpenTabOutput`, store `ManagedTab(browser, url)`. If the default isn't in our supported set or the open script fails, fall back to `env.openURL(url)` (NSWorkspace) with no tracking.

`AppDelegate` owns ONE coordinator instance and passes it to every `SessionAction.execute(...)` call. `SessionAction.openRemote` is the only call site — never call `BrowserController` or the coordinator from views.

**Identity is URL, not a per-browser tab handle.** This means a manually-opened tab at the same Claude session URL we tracked CAN be navigated by step 1 if the AppleScript walk happens to find it before our managed tab. This trade-off is documented and accepted: it keeps the code uniform across browsers and is robust to Arc's id-reassignment-on-promotion. Step 2 (focus probe) is non-mutating — it just brings the matched tab forward.

**Mock seam.** Tests use `MockSystemEnvironment` (in TerminalControllerTests) which captures executed scripts and returns canned stdout via `appleScriptOutputProvider`. The coordinator's 3-arg internal `openOrFocus(url:environment:defaultBrowser:)` lets tests inject a default browser without mutating any global.

**Arc multi-window — Accessibility required.** Arc's AppleScript dictionary refuses every "raise this window" verb (`set index`, `set frontmost`, `set main`, etc.) and rejects scalar property access (`bounds of w` errors -1728), so we can't bring the matched window forward from inside Arc's own tell block. Both `buildFocusBlock` and `buildNavigateScript` capture Arc's window UUID via `id of window N`, then call `System Events → tell process "Arc" → perform action "AXRaise"` on the AX window whose `AXIdentifier` contains that UUID (Arc surfaces it as `bigBrowserWindow-<UUID>`). AXRaise MUST run before `activate` — `activate` first causes Arc to paint its existing front window before AXRaise reorders the stack. AXRaise is wrapped in `try` so a missing Accessibility grant degrades gracefully to "matched tab is selected but wrong window stays front". `AppDelegate.applicationDidFinishLaunching` calls `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])` so macOS prompts on first launch; the option key is hardcoded as a literal to sidestep Swift 6 strict-concurrency complaints about the C global being imported as `var`. Note: macOS grants Accessibility per code signature, so a re-signed dev build (`make install`) may need the grant toggled off and on again in System Settings.

**To add a new browser:** add a case to `BrowserApp`, then handle the new case in `BrowserController.buildFocusBlock`, `buildOpenTabScript`, and `buildNavigateScript`. The compiler will surface every place that needs to be updated.

All AppleScript matchers must go through `TerminalController.escapeForAppleScript`.

## Compatibility

See the compatibility tables in the [README](README.md#compatibility) for current LLM tool and terminal app support status. Keep those tables up to date when adding or changing support for a tool or terminal app.
