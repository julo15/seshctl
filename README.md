# Seshctl

A macOS session manager for terminal-based workflows. Tracks coding sessions across Terminal.app, iTerm2, and VS Code terminals, with a native menu bar app and CLI.

![Seshctl session panel](docs/screenshot.png)

## Requirements

- macOS 13+
- Swift 6.0+ (comes with Xcode 16+) — only needed if you build from source
- Optional: [jq](https://jqlang.github.io/jq/) — used by the standalone `seshctl-uninstall` fallback for robust JSON edits. Without it, the fallback leaves your hook config files untouched and writes a `.seshctl-uninstall.bak` next to each
- Optional: `create-dmg` and the GitHub CLI for cutting releases — see [`docs/release.md`](docs/release.md)

## Install

### Download (recommended)

Grab the latest `Seshctl.dmg` from the [releases page](https://github.com/julo15/seshctl/releases/latest), open it, and drag `Seshctl.app` to `/Applications`.

> **First launch:** because Seshctl is currently self-signed (not yet notarized), macOS Gatekeeper will say *"Seshctl can't be opened because it is from an unidentified developer."* Right-click the app → **Open** → confirm. Once approved, double-clicks work normally. (This goes away once we ship Stage 1B with a Developer ID — see [Roadmap](#roadmap).)

On first launch, Seshctl shows a one-screen welcome panel. Click **Install** and it will:

- Symlink `~/.local/bin/seshctl` → the bundled CLI
- Drop a standalone `~/.local/bin/seshctl-uninstall` cleanup script (survives bundle deletion)
- Register Claude Code hooks in `~/.claude/settings.json`
- Register Codex hooks in `~/.agents/hooks.json` (and set `codex_hooks = true` in `~/.agents/config.toml`)

All operations are idempotent and reversible.

#### VS Code extension

If you use VS Code (or Cursor / VS Code Insiders), install the companion extension so Seshctl can focus terminal tabs by PID. DMG users don't need a source checkout — see [Editor Integrations](#editor-integrations) below for the in-app flow. From a source checkout you can also run the matching target — both install the same `.vsix`:

```sh
make install-vscode   # VS Code (or VS Code Insiders)
make install-cursor   # Cursor (also enables chat-thread focus for native Cursor chat sessions)
```

Reload the editor after installing to activate the extension.

#### Editor Integrations

The companion extension ships pre-built inside the app at `Seshctl.app/Contents/Resources/extensions/seshctl.vsix`. On a fresh DMG install, the **Editor Integrations** window opens automatically after the welcome dialog and lists every detected editor (VS Code, VS Code Insiders, Cursor) with an Install / Reinstall / Update button. You can revisit it any time from the menu-bar gear icon → **Editor Integrations → Configure…**.

On subsequent launches Seshctl checks the bundled extension version against what's installed and silently refreshes editors that have already opted in. Editors without the extension are left alone — the user opts in once through the Editor Integrations window.

`make install-vscode` and `make install-cursor` still work for dev iteration from a source checkout. They're no longer the only install surface — just the fast path when you're working on the extension itself.

### Updating

For v0.4.0+, the app auto-updates over Sparkle: on launch (and every 24h while running) it fetches the appcast at `https://julo15.github.io/seshctl/appcast.xml`, and when a newer version is available offers a one-click in-app install. You can also trigger a check on demand from **Settings → About → Check for Updates…**. v0.3.0 installs don't bundle Sparkle, so the one-time path to v0.4.0 is still "download the DMG and drag it over `/Applications/Seshctl.app`" — TCC grants survive because the signing identity stays the same.

### Migrating from a pre-DMG install

If you previously installed seshctl via `make install` from source (pre-v0.1.0):

1. `pkill -f SeshctlApp` to stop the old raw-exe process.
2. Install the DMG normally — the first-launch installer migrates `~/.local/bin/seshctl-cli` (real file → symlink), refreshes hook scripts with the defensive guard, and preserves your session DB.
3. macOS will re-prompt for Automation permission per browser/terminal one more time (different code signature than the ad-hoc-signed dev build). Grant once, persists forever.
4. Optional: `make clean` in your seshctl checkout removes the lingering `.build/release/SeshctlApp` raw exe (~20 MB).

### Uninstalling

Three ways out, all idempotent:

- **Recommended (clean):** From the menu bar icon (or the triple-dot menu inside the panel) → **Uninstall Seshctl…**. The confirm dialog includes an **Also delete session history** checkbox if you want `~/.local/share/seshctl/seshctl.db` removed as well. Terminal fallback: `seshctl uninstall` (add `--delete-history` for the same DB removal). Either path removes the CLI symlink, hook entries from both LLM configs, the standalone uninstaller, the marker file, and clears `codex_hooks = true` from `~/.agents/config.toml`. Then drag `Seshctl.app` from `/Applications` to Trash. macOS may still list a Seshctl entry under System Settings → Privacy & Security → Automation; that's harmless TCC residue you can remove by hand.
- **After-the-fact:** If you already trashed `Seshctl.app`, run `seshctl-uninstall` from a terminal. It's a real file in `~/.local/bin/` (not a symlink into the bundle), so it survives. Same cleanup as above.
- **Drag-to-trash and forget:** Hook scripts have a defensive guard that no-ops if `seshctl-cli` isn't on PATH. After 5 consecutive misses, hooks self-clean their own settings entries and remove `~/.local/share/seshctl/hooks`. The user data DB at `~/.local/share/seshctl/seshctl.db` stays — delete it manually if you don't want it.

### For developers (build from source)

```sh
git clone https://github.com/julo15/seshctl.git
cd seshctl
make cert-setup    # one-time: generate the self-signed code-signing identity
make install     # build + sign + install into /Applications, then launch
```

`make install` is the canonical dev loop: it rebuilds the universal binary, signs it with the self-signed cert, replaces `/Applications/Seshctl.app`, and re-launches. AppDelegate's launch-time install reconciler then refreshes the CLI symlink, the standalone uninstaller, and hook registrations automatically — a change to the bundle path, version, or executable mtime triggers it.

The first launch still needs the right-click → **Open** Gatekeeper dance (because the cert is self-signed, not Developer ID). After that, double-clicks work normally.

For producing a signed `.dmg` to share with others, see [`docs/release.md`](docs/release.md).

### LLM CLI hooks

Seshctl tracks session status through hooks for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/hooks) and Codex. The install flow — DMG first launch or `make install` — registers these automatically, and the launch-time reconciler keeps them in sync on every subsequent launch. Hook scripts live in `~/.local/share/seshctl/hooks/{claude,codex}/` and are registered in `~/.claude/settings.json` and `~/.agents/hooks.json` respectively.

## Usage

Press **Cmd+Shift+S** to toggle the session panel.

### Session list

- **j / k** or **Arrow keys** — navigate sessions
- **gg** — jump to top
- **G** — jump to bottom
- **Enter** — focus the selected session's terminal
- **f** — fork the selected Claude session into a new branched session in a new tab (then **y** to confirm, **n** to cancel)
- **o** — open session detail view
- **x** — kill session process (then **y** to confirm, **n** to cancel)
- **u** — mark the selected session as read (clears the "Unread" pill)
- **U** — mark all sessions as read (then **y** to confirm, **n** to cancel)
- **r** — cycle the source filter: all → local only → cloud only → all
- **v** — toggle list/tree view
- **h / l** — in tree mode, jump to previous/next group (h jumps to the current group's first session, then to the previous group)
- **/** — search/filter sessions
- **?** — open the keyboard help popover
- **q** or **Esc** — dismiss the panel

### Session detail

- **j / k** or **Arrow keys** — scroll line by line
- **gg** — jump to top
- **G** — jump to bottom
- **Ctrl+d / Ctrl+u** — half-page down/up
- **Ctrl+f / Ctrl+b** — full page down/up
- **q** or **Esc** — back to list

### Claude remote sessions

Seshctl can list Claude Code sessions hosted on claude.ai (Cowork) alongside local terminal sessions, and pair a local CLI with its claude.ai counterpart so Enter focuses the terminal. Until the in-app flow has built-in guidance, connecting requires a one-time manual step.

**Connecting to claude.ai**

1. Open the session panel (**Cmd+Shift+S**) and click the **⋯** button in the header (or press **Cmd+,**) to open Settings.
2. Click **Connect…**. A sign-in window opens on `claude.ai/login`.
3. **Sign in with email, not Google.** Google's "Continue with Google" flow is blocked inside embedded WebViews, so the sheet rejects it. Enter your email to request a magic link.
4. Open the magic-link email in your mail client. The link is set to open in your default browser, so clicking it won't complete sign-in inside the sheet. Instead, **right-click the link → Copy Link Address**.
5. Paste the URL into the **Paste magic-link URL** field at the top of the sign-in window and press Enter (or click **Go**). The sheet navigates to the URL, completes auth, and auto-dismisses on success.

Once connected, remote sessions appear in the panel with a cloud glyph. The connection persists until the claude.ai session cookie expires (~28 days) or you click **Disconnect** in Settings.

**Accounts that only have Google sign-in:** add an email/password or passkey on claude.ai's account settings first, then use that method in the sheet.

## Compatibility

### LLM tools

| Tool | Hooks | Transcript parsing | Notes |
|------|-------|--------------------|-------|
| Claude Code | Full | Full | All hook events, full transcript support. Sessions bridged to claude.ai (via `/remote-control`) show as a single row with a cloud glyph on line 2; Enter focuses the terminal. |
| Codex | Partial | Full | `SessionStart` hook doesn't fire until the first message is sent. No `UserPromptSubmit` (sessions never show "In Progress"). No `SessionEnd` hook — sessions close on `Stop` only. Requires `codex_hooks = true` feature flag (set automatically by the installer, cleared on uninstall) |
| Gemini | None | None | Tracked via CLI only (`seshctl-cli start --tool gemini`), no auto-hooks or transcript parsing yet |
| Cursor | Full (1.7+) | None (deferred) | Native Composer chats registered via `~/.cursor/hooks.json` (Cursor 1.7+). Workspace-level Enter-to-focus works out of the box; chat-thread targeting (landing the Composer panel on the exact conversation, including reopening closed chats) requires the companion extension. DMG users install it from **Editor Integrations** in-app (see [Editor Integrations](#editor-integrations)); source-checkout devs can run `make install-cursor`. Without the extension, Enter degrades to workspace focus only |

### Terminal apps

| App | Focusing | Notes |
|-----|----------|-------|
| Terminal.app | Full | TTY-based tab matching via AppleScript |
| VS Code | Full | Requires the companion extension for terminal tab focusing. DMG users install from [Editor Integrations](#editor-integrations); source-checkout devs can run `make install-vscode` |
| Cursor | Full | Requires the companion extension. Workspace + chat-thread focusing: `open -b` flips Cursor to the target workspace window, then the extension calls `composer.openComposer` to land the Composer panel on the exact chat. Reopening a closed chat replaces the currently-active tab slot (the displaced chat stays accessible via history). Without the extension, focus degrades to workspace-level only. Terminal-tab focus (for Claude Code running inside Cursor's integrated terminal) works via the same extension and the `/focus-terminal` URI route. DMG users install from [Editor Integrations](#editor-integrations); source-checkout devs can run `make install-cursor` |
| iTerm2 | Implemented | TTY-based tab matching via AppleScript, not extensively tested |
| Ghostty | Full | Working-directory matching via native AppleScript API; resume via surface configuration |
| Warp | Full | DB-assisted tab matching via Warp's internal SQLite; resume via keystroke simulation. No split pane support yet |
| cmux | Full | AppleScript focus across cmux's two-level hierarchy (workspace = sdef `tab`, horizontal tab within = sdef `terminal`). `$CMUX_WORKSPACE_ID` and `$CMUX_SURFACE_ID` are captured by the session-start hook and packed into `windowId` as `"<workspace>\|<surface>"`; focus matches `id of tab` for the workspace, then `focus`es the matching `terminal` so both levels are raised. AppleScript resume via `new tab` + `input text`. **Fork** uses cmux's bundled CLI (`tree --json` → `new-surface` → `send`) to land a sibling tab in the same pane — see [cmux setup](#cmux-setup) for the required automation-mode opt-in |
| Conductor.build | None | No focus support — Conductor exposes no AppleScript dictionary, URI handler, or extension API for targeting a specific terminal pane. Implementing focus requires an integration point from Conductor |
| Other | Basic | Falls back to window-name matching via System Events |

The first time seshctl focuses a session in an AppleScript-driven terminal (Terminal.app, iTerm2, Ghostty, Warp, or cmux) or browser (Chrome, Arc, Safari), macOS will prompt you to grant Seshctl Automation permission for that target. **Once granted, the permission persists across rebuilds and updates** — Seshctl ships with a stable code-signing identity, so TCC caches each grant by signature. You can review or revoke these grants in System Settings → Privacy & Security → Automation.

On first launch, SeshctlApp also requests **Accessibility** permission (System Settings → Privacy & Security → Accessibility) — separate from Automation. This is used when flipping to a remote Claude session that lives in a non-frontmost Arc window: Arc's AppleScript dictionary doesn't expose any "raise this window" verb, so seshctl falls back to System Events' `AXRaise` to bring the matched window forward. Without the grant, the right tab still gets selected, but the wrong Arc window may stay visually on top.

#### cmux setup

cmux's fork-into-the-existing-workspace path drives cmux's bundled CLI (`/Applications/cmux.app/Contents/Resources/bin/cmux`) over its Unix socket. By default cmux gates that socket with `socketControlMode: "cmuxOnly"` — only descendants of the cmux GUI process can connect, which excludes SeshctlApp when launched from the Dock, `make install`, or a LaunchAgent. With the default mode, fork silently falls through to creating a new workspace.

To enable in-pane fork, opt cmux into a permissive socket mode by editing `~/.config/cmux/cmux.json`:

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
  "schemaVersion": 1,

  "automation": {
    "socketControlMode": "automation"
  }
}
```

Then restart cmux (quit and relaunch). `automation` keeps the socket file at `0600` (only your user account can connect) but disables the process-ancestry check, which is the recommended choice for SeshctlApp. `allowAll` also works — it additionally `chmod`s the socket to `0666`, which any local process running as your user can then connect to; only choose this if you understand the trade.

Verify the change took effect:

```sh
ls -la ~/Library/Application\ Support/cmux/cmux.sock
# expect: srw------- (automation) or srw-rw-rw- (allowAll)
env -i HOME=$HOME PATH=$PATH /Applications/cmux.app/Contents/Resources/bin/cmux ping
# expect: PONG
```

If `cmux ping` returns `Failed to write to socket (Broken pipe, errno 32)`, the config didn't take effect — double-check that `cmux.json` parsed cleanly (it's JSONC, but malformed JSON is silently rejected) and that you restarted cmux after editing it.

### Browsers

Seshctl can focus an existing tab for a remote Claude Code session in these browsers; if no browser has the tab open, it falls back to the user's default browser.

| Browser | Focus existing tab | Notes |
| --- | --- | --- |
| Chrome (Google Chrome) | ✅ | macOS AppleScript dictionary |
| Arc | ✅ | Walks spaces; Little Arc popovers and archived spaces are skipped silently. Multi-window focus uses System Events `AXRaise` (requires Accessibility permission, prompted on first launch) — without the grant the matched tab is selected but the wrong window may stay frontmost |
| Safari | ✅ | macOS AppleScript dictionary |

When you flip between remote sessions in seshctl, the existing tab opened by seshctl is reused (its URL is set to the new session) instead of accumulating one tab per session. The tab is identified by the URL we last set on it (matched as the `/code/session_<id>` substring), so it survives Arc's Little-Arc → main-window promotion and is portable across all three browsers. A trade-off: if you manually open a tab at the same Claude session URL we tracked, our flip might navigate yours instead of ours.

## Roadmap

These deferred phases are tracked in [`.agents/plans/2026-05-08-1151-seshctl-real-app-phase1.md`](.agents/plans/2026-05-08-1151-seshctl-real-app-phase1.md) under "Future Phases":

| Phase | What | Status / Tracking |
|---|---|---|
| **1B — Developer ID + notarization** | Drop the right-click-to-Open ritual on first install. One-time TCC re-prompt expected. | Tracking: `<LIN-ID>` (or "TODO — file ticket") |
| **2 — Sparkle auto-updates** | In-app one-click updates over an EdDSA-signed appcast on GitHub Pages. | **Done in v0.4.0.** Plan: [`.agents/plans/2026-05-20-2300-sparkle-auto-updates.md`](.agents/plans/2026-05-20-2300-sparkle-auto-updates.md) |
| **3 — GitHub Actions CI release** | `git tag v0.x.y && git push --tags` produces a complete release with no manual steps. Only worth it once release cadence justifies it. | Tracking: `<LIN-ID>` (or "TODO — file ticket") |

Each phase has explicit triggers, first concrete steps, acceptance criteria, and risks documented in the plan file.

## Development

```sh
make build          # debug build
make test           # run all tests
make run-app        # run menu bar app (debug)
make run-cli ARGS="list"  # run CLI with arguments
make help           # see all available commands
```
