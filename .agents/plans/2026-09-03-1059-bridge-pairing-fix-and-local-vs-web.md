# Plan: Fix bridged local/remote pairing + let the user choose local vs. web

**Status: implemented.** This document is written after the fact as a review brief — the
work described here is already in the working tree (uncommitted). Steps are checked off
because they are done, not because they are planned.

## Working Protocol
- Per AGENTS.md: **always run tests via subagents**, 30s timeout for tests, 120s for builds.
  Run `make kill-build` first if anything looks stale.
- `make install` is the canonical dev loop for observing the change in the real app.

## Overview

Two things, one reported together:

1. **Bug — bridged pairs stopped grouping.** A local CLI session started with
   `/remote-control` also exists on claude.ai. Seshctl is supposed to pair the two and
   render one row. It stopped pairing: every bridged conversation split back into two
   unlinked rows (one local, one remote). Root cause: **Claude Code changed the transcript
   record that carries the join key**, and `TranscriptBridgeScanner` only recognized the
   old shape, so it returned `nil` for every transcript.

2. **Feature — pick which half to open.** Once a row is a pair, Enter has to choose, and it
   chooses the terminal. There was no way to say "open this one on the web instead."
   Added `w` (and a click target on the row's cloud glyph).

The two are coupled: (2) is unreachable while (1) is broken, because there are no pairs.

## The bug, precisely

`BridgeMatcher` pairs a local to a remote when the local's transcript declares which
claude.ai session it's bridged to. That declaration used to look like this:

```json
{"type":"system","subtype":"bridge_status",
 "content":"/remote-control is active. Code in CLI or at https://claude.ai/code/session_<SUFFIX>",
 "url":"https://claude.ai/code/session_<SUFFIX>"}
```

`TranscriptBridgeScanner` matched on `type == "system" && subtype == "bridge_status"`,
pulled `url`, and converted `session_<SUFFIX>` → `cse_<SUFFIX>` (the API-native id).

Claude Code now writes a dedicated record instead, carrying the API id verbatim:

```json
{"type":"bridge-session","sessionId":"<local uuid>",
 "bridgeSessionId":"cse_<SUFFIX>","lastSequenceNum":0,
 "ownerAccountUuid":"…","ownerOrganizationUuid":"…"}
```

Neither live transcript on this machine contained a single `bridge_status` event. The
scanner's `guard` fell through on every line, `extractBridgedRemoteId` returned `nil` for
every session, `BridgeMatcher.match` produced zero pairs, and `bridgedLocalIds` /
`bridgedRemoteIds` were both empty — so the remote twin was never filtered out of
`activeRows`/`recentRows` and the local twin never rendered its cloud glyph.

**The failure was silent.** No error, no log line, no test failure. Every unit test kept
passing because they all fed the scanner hand-written *legacy-shape* fixtures. The
integration tests in `SessionListViewModelTests` did too — `writeTranscript(bridgedToCseId:)`
synthesized a `bridge_status` line. The whole test suite was validating a format that
production no longer emits. That's the most important thing for a reviewer to notice: this
class of bug is invisible to the existing tests by construction.

## Fix

`TranscriptBridgeScanner.extractBridgedRemoteId(transcript:)` now switches on `type` and
accepts both shapes:

- `"bridge-session"` → take `bridgeSessionId` (already `cse_`-prefixed) via `normalizedCseId`.
- `"system"` + `subtype == "bridge_status"` → derive from `url` via the existing
  `cseId(fromWebUrl:)`.

Last matching record in the file wins, preserving the previous "most recent bridge event
wins" semantics across both shapes. Both are kept because a transcript resumed across a CLI
upgrade can contain either, and older transcripts on disk still only have the legacy shape.

`normalizedCseId` tolerates an unprefixed id (returns `cse_<raw>`) and rejects empty /
prefix-only values so a malformed record can't pair with a remote.

**Verified against production data**, not just fixtures: both live transcripts in
`~/.claude/projects/-Users-julianlo-Documents-me-seshctl/` now resolve —
`09e58d49-…` → `cse_017aNW1FKSDu8VqUHKoyAKit` and `4e72d417-…` → `cse_01XnJs9ivWwjpgBFF1McKZ6y`.
The first matches the bridge id of the session this work was done in. (Verified with a
throwaway test that read the real files; deleted afterward, since a committed test can't
depend on a developer's home directory.)

## Feature: local vs. web

### User experience

A bridged row shows a laptop glyph **and** a cloud glyph on line 2. Both halves are now
reachable:

| Input | Result |
|---|---|
| **Enter** / **e** | Focus the local terminal (unchanged) |
| **w** | Open the session on claude.ai |
| Click the cloud glyph | Same as `w` |

On a pure-remote row, `w` does what Enter already does (opens claude.ai) — harmless
symmetry rather than a special case. On an unbridged local row or a recall result, `w`
no-ops: there is no web session to open, so the handler returns rather than guessing.

### Architecture

`SessionListViewModel.refresh()` already computed `BridgeMatcher.Pair` values and threw
away everything but two id sets. It now publishes a third projection of the same output:

- `bridgedLocalIds: Set<String>` — row renders the cloud glyph (existing)
- `bridgedRemoteIds: Set<String>` — twin filtered out of the row slices (existing)
- `bridgedRemoteIdByLocalId: [String: String]` — the full map (new)

The map backs two accessors:

- `bridgedRemote(for: Session) -> RemoteClaudeCodeSession?`
- `selectedWebUrl: URL?` — remote row → its own `webUrl`; bridged local row → the twin's
  `webUrl`; anything else → `nil`

Keeping the map alongside the sets (rather than deriving one from the others) avoids an
O(n) scan per row render on the 2s refresh tick.

Both the keyboard and mouse paths converge on the **existing** action:

```
w key   → AppDelegate.openSelectedOnWeb → vm.selectedWebUrl ─┐
                                                             ├→ SessionAction.execute(.openRemote(url))
cloud   → SessionRowView.onOpenWeb → AppDelegate closure ────┘        → RemoteBrowserCoordinator
click     (plumbed via RootView → SessionListView/SessionTreeView)
```

This is deliberate: `.openRemote` is what Enter on a remote row already dispatches, so
managed-tab reuse in `RemoteBrowserCoordinator` is shared. Per AGENTS.md there must be
exactly one browser-opening path, and this adds no second one.

`onOpenWeb` is only handed to *bridged* rows (`bridgedLocalIds.contains(session.id)`); an
unbridged row gets `nil` and the cloud glyph stays a static marker — which is moot in
practice since the glyph isn't rendered for unbridged rows at all. Belt and braces.

## Impact Analysis

- **New files**: none.
- **Modified — fix**:
  - `Sources/SeshctlCore/TranscriptBridgeScanner.swift` — dual-shape parse + `normalizedCseId` + header docs.
- **Modified — feature**:
  - `Sources/SeshctlUI/SessionListViewModel.swift` — `bridgedRemoteIdByLocalId`, `bridgedRemote(for:)`, `selectedWebUrl`.
  - `Sources/SeshctlApp/AppDelegate.swift` — `w` key case, `openSelectedOnWeb`, `onOpenWeb` closure, `RootView` plumbing.
  - `Sources/SeshctlUI/SessionRowView.swift` — `onOpenWeb` param, `cloudMarker` (button when handler present, static glyph otherwise).
  - `Sources/SeshctlUI/SessionListView.swift`, `SessionTreeView.swift` — `onOpenWeb` plumbing; footer hint.
  - `Sources/SeshctlUI/HelpPopover.swift` — `w` row in the Act section.
- **Modified — docs**: `README.md` (keybindings, new "Bridged sessions: local or web" section, LLM-tools table), `AGENTS.md` (new "Bridged Sessions" section).
- **Modified — tests**: `Tests/SeshctlCoreTests/TranscriptBridgeScannerTests.swift`,
  `Tests/SeshctlUITests/SessionListViewModelTests.swift`.
- **Dependencies**: none added.
- **Public API**: additive only. Every new parameter has a default; no existing signature
  changed meaning. `SessionRowView.init` gained a trailing defaulted `onOpenWeb:`.
- **Not touched**: `BridgeMatcher` is unchanged — it was never the bug. `SessionAction`,
  `BrowserController`, and `RemoteBrowserCoordinator` are unchanged.

## Key Decisions

- **Keep the legacy shape rather than replace it.** Transcripts on disk predating the CLI
  change still only have `bridge_status`, and a session resumed across an upgrade can hold
  both. Cost is one extra `switch` case.
- **Last record wins, across both shapes.** Preserves the pre-existing rebridge semantics
  without special-casing which shape is "newer". Pinned by `mixedShapesLastWins`.
- **Publish the map, don't derive it.** `bridgedLocalIds`/`bridgedRemoteIds` could be
  computed from the map, but they're read per-row-render on a 2s tick; three cheap
  projections beat one O(n) recomputation per row. Consistency is asserted by
  `bridgedPairMapMirrorsIdSets`.
- **`Dictionary(_:uniquingKeysWith:)`, not `uniqueKeysWithValues:`.** `BridgeMatcher`
  guarantees one pair per local today, but the trapping initializer would turn any future
  relaxation of that invariant into a crash on the refresh tick.
- **`w` for the binding.** Unused; mnemonic for "web". Guarded by the same
  pending-kill/fork/mark-all-read check as the other non-destructive actions.
- **Cloud glyph as the mouse affordance.** It already existed as a static bridged marker in
  exactly the right place; making it the click target adds discoverability without new
  chrome. It only becomes a button when a handler is supplied.
- **`w` no-ops instead of falling back to Enter's behavior.** Silently focusing a terminal
  when the user asked for the web would be worse than doing nothing.

## Implementation Steps

### Step 1: Fix the scanner
- [x] Dual-shape parse in `TranscriptBridgeScanner.extractBridgedRemoteId(transcript:)`.
- [x] `normalizedCseId(_:)` helper — tolerate unprefixed, reject empty/prefix-only.
- [x] Rewrite the type's header doc to describe both shapes and the last-wins rule; fix the
      now-inaccurate `transcriptPath` doc that referenced a missing `url` field.

### Step 2: Expose the pairing
- [x] `bridgedRemoteIdByLocalId` published in `refresh()` alongside the two id sets.
- [x] `bridgedRemote(for:)` and `selectedWebUrl` accessors.

### Step 3: Keyboard path
- [x] `w` case in `AppDelegate.handleNormalKey`, guarded like the other actions.
- [x] `openSelectedOnWeb(vm:)` — resolve URL, `markSelectedRowRead()`, dispatch `.openRemote`.

### Step 4: Mouse path
- [x] `onOpenWeb` on `SessionRowView`; `cloudMarker` renders a `.plain` button when supplied.
- [x] Plumb `AppDelegate → RootView → SessionListView`/`SessionTreeView`, wired only for bridged rows.

### Step 5: Docs
- [x] `HelpPopover` Act section, `SessionListView` footer hint.
- [x] `README.md` — keybindings, "Bridged sessions: local or web", LLM-tools table note.
- [x] `AGENTS.md` — new "Bridged Sessions" section, including the debugging note.

### Step 6: Tests
- [x] Scanner: `bridgeSessionRecord`, `multipleBridgeSessionRecords`, `bridgeSessionMissingId`,
      `bridgeSessionEmptyId`, `bridgeSessionUnprefixedId`, `mixedShapesLastWins`,
      `readsBridgeSessionFileFromDisk`.
- [x] View model: `writeBridgeSessionTranscript` helper + `refreshPairsBridgedPairCurrentShape`,
      `bridgedPairMapMirrorsIdSets`, `selectedWebUrlForBridgedLocal`,
      `selectedWebUrlNilForUnbridgedLocal`, `selectedWebUrlForRemoteRow`.

### Step 7: Build, test, install
- [x] `swift build` — clean.
- [x] Full `swift test` via subagent — 973 tests, 84 suites, all pass.
- [x] `make install` — built, signed, relaunched from `/Applications`.

## Acceptance Criteria

- [x] [test] Scanner extracts the id from a `bridge-session` record.
- [x] [test] Scanner still extracts from a legacy `bridge_status` event.
- [x] [test] Mixed-shape transcript resolves to whichever record is last.
- [x] [test] Malformed `bridgeSessionId` (empty, `cse_` alone) yields `nil`.
- [x] [test] View model pairs local↔remote off the current shape, and the twin is absent
      from `activeRows` + `recentRows`.
- [x] [test] `bridgedRemoteIdByLocalId` keys == `bridgedLocalIds`, values == `bridgedRemoteIds`.
- [x] [test] `selectedWebUrl` — twin's URL for a bridged local, own URL for a remote, `nil`
      for an unbridged local.
- [x] [test] Full suite green.
- [x] [verified] Real transcripts on disk resolve to their real `cse_` ids.
- [ ] [test-manual] **Not yet confirmed by the user.** With a bridged session live: the pair
      renders as one row with laptop + cloud glyphs; Enter focuses the terminal; `w` and a
      click on the cloud glyph both open claude.ai.

## Edge Cases

- **Transcript with both shapes** (resumed across a CLI upgrade) → last record wins. Pinned
  by `mixedShapesLastWins`.
- **`bridgeSessionId` without the `cse_` prefix** → normalized to `cse_<raw>`. Defensive;
  not observed in the wild.
- **Empty or `cse_`-only id** → `nil`, so it can't pair.
- **Pair dissolves mid-session** (local goes terminal, or the remote drops out of
  `remoteSessions`) → `bridgedRemote(for:)` returns `nil`, `selectedWebUrl` returns `nil`,
  `w` no-ops, and the remote reappears as its own row. Existing `pairDissolvesOnCompleted`
  covers the row-slice half.
- **Stale stored `transcript_path`** (user `cd`s into a worktree mid-session) — unchanged
  behavior: `refresh()` still resolves through `TranscriptParser.resolveExistingTranscript`,
  which globs `~/.claude/projects/*/<convId>.jsonl`. Not affected by this change, but it's
  the other half of "why might the transcript not be found."

## Review Notes / Where to Look Hard

1. **Is the dual-shape parse right?** `Sources/SeshctlCore/TranscriptBridgeScanner.swift`.
   Note the `guard let cseId = cseId(fromWebUrl: url)` in the `"system"` branch shadows the
   static method name — legal (the binding isn't in scope on its own RHS) and pre-existing,
   but worth a second pair of eyes.
2. **The test suite was validating a dead format.** Every pre-existing bridge test used
   legacy-shape fixtures. New tests cover the current shape, but consider whether more of
   the *existing* fixtures should migrate, or whether keeping both is the right call.
3. **Three projections of one computation** must stay in sync in `refresh()`. If a reviewer
   prefers one source of truth, the alternative is a stored `[Pair]` with computed sets —
   traded away for per-render cost.
4. **`markSelectedRowRead()` in `openSelectedOnWeb`** marks the *selected* row. For a
   bridged pair the selected row is the local twin, which is the visible one, so that's the
   intended read receipt. The remote twin's own `lastReadAt` is not stamped — same as the
   pre-existing Enter-on-bridged-local behavior, but confirm that's desired.
5. **Untouched neighbors:** `Sources/SeshctlCore/FirstLaunchInstaller.swift`,
   `Sources/seshctl-cli/Install.swift`, `scripts/seshctl-uninstall.sh`, and
   `Tests/SeshctlCoreTests/FirstLaunchInstallerTests.swift` were already modified in the
   working tree before this work (in-flight Codex hooks deprecation) and are **not part of
   this change**. Nothing here was committed.
