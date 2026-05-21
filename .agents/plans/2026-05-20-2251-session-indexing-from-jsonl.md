# Session Indexing from Claude Code JSONL Logs

**Status:** research / scoping. No code yet.
**Goal:** Decide what fields to extract from Claude Code session logs to make `seshctl`'s session-list view useful at a glance.
**Hand-off:** This doc captures findings from a research conversation on 2026-05-20. A new agent should be able to pick up from here and start designing/implementing the indexer.

---

## Where the data lives

Claude Code writes one JSONL per session under:

```
~/.claude/projects/<project-slug>/<session-id>.jsonl
```

Where `<project-slug>` is the cwd with slashes replaced by dashes (e.g. `-Users-julianlo-Documents-me-seshctl`). There is also a sibling directory `~/.claude/projects/<project-slug>/<session-id>/` containing per-session `subagents/`, `tool-results/`, and `memory/` subdirs — these are auxiliary and **not** the canonical message log. Read the `.jsonl` file.

Each line is a JSON object with a `type` field. Observed `type` values:

| `type` | `subtype` | meaning |
|--------|-----------|---------|
| `user` | – | user message (incl. tool_results posted back as user) |
| `assistant` | – | assistant message |
| `system` | `away_summary` | the "recap" message after idle |
| `system` | `turn_duration` | end-of-turn marker with `durationMs` + `messageCount` |
| `system` | `stop_hook_summary` | Stop-hook output after turn end |
| `last-prompt` | – | every queued user prompt, even before it's processed |
| `pr-link` | – | PR created/touched during session |
| `permission-mode` | – | permission mode at that point in time |
| `attachment` | – | file/image attachment |
| `file-history-snapshot` | – | tracked file backups |
| `queue-operation` | – | enqueued user input (raw, pre-processing) |

Every record has `timestamp`, `sessionId`, `cwd`, `gitBranch`, `version`, `userType`, `entrypoint`, `uuid`, `parentUuid`.

---

## The "recap" / `away_summary` feature

### What it is

A `system` record of `subtype: "away_summary"` that Claude Code writes after the user goes idle. The `content` field is a short LLM-generated status: where the session is, what's next, and a `(disable recaps in /config)` tail.

Example:

```json
{
  "type": "system",
  "subtype": "away_summary",
  "content": "Shipped two PRs to main today: agent-badge polish (#31) and hide-recent-sessions (#32), both squash-merged after review-gate. Nothing in flight; waiting on your next instruction. (disable recaps in /config)",
  "timestamp": "2026-05-06T17:48:04.022Z",
  "sessionId": "...",
  "cwd": "...",
  "gitBranch": "main",
  "parentUuid": "..."
}
```

### When it fires (empirically verified across 37 recaps in 13 sessions)

**Idle threshold ≈ 3 minutes** (clustered at 182–186 s, ≈84% of cases).

- The timer starts at the **end of Claude's turn**. The `parentUuid` of every `away_summary` points to one of: `system/turn_duration`, `system/stop_hook_summary`, or the final `assistant` message.
- The parent is **never another `away_summary`** — recaps do not chain. Each new recap is anchored to the most recent end-of-turn.
- Outliers exist (200, 216, 320, 398, 493, 684 s). Likely cause: wall-clock timer gated on app foreground / not-mid-API-call, so it can drift past 3 min if the app was backgrounded or the laptop slept. Not multiples of the threshold, so not "missed-tick retry".

Distribution across the 37 observed recaps:

| stat | s |
|------|---|
| min | 182 |
| p50 | 184 |
| p75 | 184 |
| p90 | 320 |
| max | 684 |

### How to extract recaps

```sh
# all recaps in one session
jq -c 'select(.subtype=="away_summary")' \
  ~/.claude/projects/<project-slug>/<session-id>.jsonl

# every recap across every project (timestamp, cwd, content)
find ~/.claude/projects -maxdepth 2 -name '*.jsonl' -print0 \
  | xargs -0 jq -r 'select(.subtype=="away_summary") | "\(.timestamp)\t\(.cwd)\t\(.content)"'
```

---

## What else is worth indexing

Beyond `away_summary`, ranked by usefulness for a session list view.

### Tier 1 — show in every row

1. **First user prompt** — best natural "title".
   ```sh
   jq -r 'select(.type=="user" and .isMeta!=true) | .message.content' file.jsonl | head -n1
   ```
   Truncate to ~80 chars. Note: `message.content` can be a string OR an array of content blocks; handle both.

2. **`last-prompt` records** — every queued user input is logged with field `lastPrompt`. The most recent = current ask. The full chain = the arc of the session.

3. **`cwd` + `gitBranch`** — both carried on every record. **Branch *changes*** are a strong status signal (e.g. `main → julo/feature → main` ⇒ session likely shipped).

4. **Last activity timestamp** — for sort order and "X minutes ago" display.

### Tier 2 — strong status signals

5. **`pr-link` records** — `{prNumber, prUrl, prRepository, timestamp}`. Dedup by `prNumber` → "shipped #31, #32". The biggest single signal for in-flight vs done.

6. **Latest `away_summary`** — already covered. Old ones tell the story of how the goal evolved; the latest is essentially a human-readable status.

7. **Latest `TaskList` / `TaskUpdate` tool_use snapshot** — current todo state with in_progress / completed counts. Shows where the session left off.

8. **`system/turn_duration`** — last one carries total `durationMs` and cumulative `messageCount`.

### Tier 3 — texture / facets

9. **Tool-use histogram** — count `.message.content[].name` across all `assistant` messages. E.g. `Bash:41 Read:34 Edit:23 Agent:7`. Distinguishes exploration sessions from code-writing from agent-orchestration sessions at a glance.

10. **Subagent invocations** — `Agent` tool_uses with `subagent_type` + `description`. Tells you "this session ran /review-gate, /implement, etc."

11. **`message.usage`** on assistant rows — sum input/output/cache_read/cache_creation for token totals and rough cost.

12. **`message.model`** — varies per session (`claude-opus-4-7`, `claude-sonnet-4-6`, etc.).

13. **`permissionMode`** — `bypassPermissions` vs `default` makes a useful badge (the "YOLO session" indicator).

14. **`file-history-snapshot.trackedFileBackups`** keys = files touched. Useful for a "files modified" facet.

### Composite session status (derived)

| State | Heuristic |
|-------|-----------|
| **Active** | Last activity < ~3 min ago, no `away_summary` after it |
| **Idle** | `away_summary` is the most recent record |
| **Shipped** | Ends on `main` with at least one merged PR (cross-check via `gh`) |
| **In flight** | Last branch ≠ `main`, has open PR |
| **Abandoned** | Idle > N hours (tunable), no PR |

---

## Suggested row layout for the list view

```
┌─ first-prompt (truncated) ─────────────────────┐  branch  • cwd basename
│ ↳ latest away_summary (one line)               │  ↻ 2h ago • 47 turns
│ PR #31, #32 • Bash 41 Edit 23 Agent 7          │  [bypass] [opus-4-7]
└────────────────────────────────────────────────┘
```

The high-leverage triple is **first prompt + latest away_summary + PRs** — "what they asked → where it ended up → did anything ship" in one glance.

---

## Open questions for the next agent

1. **Indexing strategy.** Walk JSONLs on demand vs. maintain a derived SQLite/JSON index that gets updated incrementally? On-demand is probably fine for current scale (dozens of files) but won't survive years of history.
2. **Schema robustness.** A few gotchas already hit during research:
   - `uuid` can be `null` on some records (skip them when building parent index).
   - `message.role` is usually a string but at least one record had it shaped differently — guard with `try/catch`.
   - Timestamps include fractional seconds (`.805Z`); `fromdateiso8601` chokes on them. Strip with `sub("\\.[0-9]+Z$";"Z")`.
   - `message.content` is sometimes a string, sometimes an array of blocks.
3. **How does the session list interact with `seshctl`'s existing "recent/closed sessions" concept?** Recall: a recent PR (#32) hides closed sessions by default and only shows them in search. Make sure new metadata extraction respects that.
4. **Cross-project view vs. per-project view.** Should the list be scoped to the current cwd's project-slug, or global across `~/.claude/projects/`?
5. **Cost of parsing.** Some session files are >1 MB. Streaming jq is fine, but if the indexer loads them eagerly we'll want to memoize.

---

## Pointers

- Canonical example session with multiple recaps (3): `~/.claude/projects/-Users-julianlo-Documents-me-seshctl/20128a4b-81c0-425d-9fdd-67c07df24110.jsonl`
- Heaviest recap session (8 recaps): `~/.claude/projects/-Users-julianlo-Documents-me-assistant/05f14ab2-88f1-4a24-be3d-e00aba9bc07c.jsonl`
- Research scratch scripts were written to `/tmp/analyze_recaps*.sh` and `/tmp/recap_gaps*.tsv` during the conversation but were not preserved — they're easy to rebuild from the jq snippets above.
