# Remote Row Recap — Research & Options

**Date:** 2026-05-21
**Driver:** Local Claude rows now show the latest `away_summary` recap (PR #43). Can we surface anything equivalent on **pure-remote** (claude.ai Cowork) rows, which today show only `title`?

**Method:** Extended `.agents/spikes/claude-ai-cookie-spike` to dump the full list response and blind-probe ~9 candidate per-session detail endpoints. Re-ran with `?limit=N` and `?event_type=assistant` variants. Raw output in `.agents/spikes/claude-ai-cookie-spike/out/`.

---

## TL;DR

- **No "recap" field exists on the cloud side.** Not on the list endpoint, not on the per-session GET, not on any sub-endpoint that returns 200.
- **The only viable signal is the latest `assistant` event** from `/v1/code/sessions/<id>/events`. The bodies read exactly like recaps (see samples below).
- **Cost is manageable** with `?limit=10` (~17 KB per stale session) + caching keyed on `last_event_at` from the list response.
- **Server doesn't filter by event type** — we paginate small and filter client-side.

---

## What data we have

### 1. List endpoint — `GET /v1/code/sessions?limit=50`

200 OK. Per-session shape (one entry from the response, fields we already model marked ✅):

```json
{
  "id": "cse_01SoLb881Yov…",                              // ✅ id
  "title": "primary",                                      // ✅ title (set at create, doesn't update)
  "status": "active",                                      // ✅ status
  "worker_status": "idle",                                 // ✅ workerStatus
  "connection_status": "disconnected",                     // ✅ connectionStatus
  "created_at": "2026-05-15T14:18:37.629905Z",             // ✅ createdAt
  "last_event_at": "2026-05-20T17:51:02.571884Z",          // ✅ lastEventAt  ← cache key candidate
  "unread": true,                                          // ✅ unread
  "environment_kind": "bridge",                            // ✅ environmentKind
  "config": {
    "model": "claude-opus-4-7[1m]",                        // ✅ model
    "sources": [
      {
        "type": "git_repository",
        "url": "https://github.com/julo15/assistant",      // ✅ repoUrl
        "revision": "main",                                // ✗ not modeled
        "allow_unrestricted_git_push": true,               // ✗ not modeled
        "sparse_checkout_paths": []                        // ✗ not modeled
      }
    ],
    "outcomes": [
      {
        "type": "git_repository",
        "git_info": {
          "branches": ["main"],                            // ✅ branches
          "repo": "julo15/assistant",                      // ✗ not modeled (redundant with sources.url)
          "type": "github"                                 // ✗ not modeled
        }
      }
    ]
  },
  "environment_id": "",                                    // ✗ not modeled (often empty)
  "tags": ["remote-control-repl"],                         // ✗ not modeled  ← interesting
  "external_metadata": {                                   // ✗ not modeled  ← interesting
    "current_branches": { "julo15/assistant": "main" }
  }
}
```

**Top-level:** `{ data: [...], next_cursor: string, resume_token: string }`. `resume_token` is something we don't currently use.

### 2. Per-session GET — `GET /v1/code/sessions/<id>`

200 OK. Response is wrapped in `{ response_shape: { ... } }` for some reason. Adds 3 fields beyond the list entry:

- `client_presence` — array (empty in our captures). Probably "who's looking at this right now."
- `security_tier` — string ("standard").
- `updated_at` — separate from `last_event_at`. Unknown semantics.

**No new recap-like content.** Not worth a second call per session.

### 3. Sub-endpoint sweep

| Endpoint | Status | Notes |
|---|---|---|
| `/messages` | 404 | |
| `/messages?limit=50` | 404 | |
| `/turns` | 404 | |
| `/history` | 404 | |
| `/outcomes` | 404 | |
| `/summary` | 404 | (despite being the most-promising name) |
| `/files` | 501 | `{"error": {"message": "Feature not implemented", "type": "api_error"}}` |
| `/events` | 200 | ✅ — the only one that returns useful data |

### 4. Events endpoint — `GET /v1/code/sessions/<id>/events`

200 OK. Cursor-paginated. Default `limit=50`. **Newest-first.** Top-level:

```json
{ "data": [...events...], "next_cursor": "1182" }
```

Each event:

```json
{
  "event_id": "uuid",
  "event_type": "user" | "assistant" | "result",
  "sequence_num": "1229",        // string, monotonic, descending in the list
  "created_at": "...",
  "source": "client" | "worker",
  "payload": { ... }             // shape varies by event_type
}
```

**`assistant` payload (the recap-equivalent):**

```json
{
  "type": "assistant",
  "message": {
    "id": "msg_011pcN…",
    "role": "assistant",
    "model": "claude-opus-4-7",
    "content": [
      { "type": "text", "text": "Pushed. Commit `d2daa69`. Added to `tasks.md` …" }
    ],
    "usage": { ... },
    "stop_reason": null
  },
  "session_id": "cse_…",
  "request_id": "req_…",
  "uuid": "..."
}
```

Three real assistant payloads from your sessions read exactly like recaps:

> *"Pushed. Commit `d2daa69`. Added to `tasks.md` → Money: Enter 5/19 Golfzon bill into Splitwise — Julian paid the bill…"*
>
> *"Saved at `people/danny-walker.md`. Captured: family (Casey + Colby + Tatum), the Sep 2025 dinner vibe…"*
>
> *"I can see the issue from the screenshot — the calendar content below the sheet is at full brightness while the content above is dimmed…"*

These are higher-quality than typical `lastReply` strings because they're terminal assistant turns of a complete reasoning cycle.

**`user` payload:** `message.content` is a plain string (not an array of blocks).
**`result` payload:** turn-summary metadata (`duration_ms`, `num_turns`, `total_cost_usd`, `subtype: "success"`). **No text recap field.**

### 5. Pagination + filtering behavior

| Probe | Bytes | Outcome |
|---|---|---|
| `?limit=1` | 399 B | 1 event |
| `?limit=5` | 5,122 B | 5 events |
| `?limit=10` | 17,294 B | 10 events |
| default (50) | 158-400 KB | per session |
| `?event_type=assistant&limit=1` | 399 B | **returned a `user` event** — server ignores the filter |
| `?type=assistant&limit=1` | 399 B | same |
| `?filter=assistant&limit=1` | 399 B | same |

**Implication.** We have to filter client-side. `?limit=1` is too aggressive — the latest event is frequently a `user` event the user just sent and we'd never see the recap. `?limit=10` virtually guarantees ≥1 assistant event in normal conversations (sample: `[user, result, assistant, user, assistant, user, assistant, assistant, user, assistant]`).

---

## Cost model

Steady-state per refresh (every 2s while panel is open):

- **List call**: 1 fixed (already happens today). ~5-10 KB typical.
- **Events calls**: only fire for sessions whose `last_event_at` advanced since the cached value. ~17 KB each at `?limit=10`.

Examples:
- All 20 remote sessions idle → 0 events calls / refresh.
- One session got a reply just now → 1 events call = ~17 KB.
- User pasted a multi-message script across 3 sessions → 3 events calls = ~50 KB.
- Worst case (first refresh after launch, all 20 sessions have new activity): 20 × 17 KB = ~340 KB.

Compared to default-limit polling (which we are NOT doing): would be 20 × 300 KB = 6 MB per refresh.

The `last_event_at` cache key is **strictly better** than the local-side mtime cache, because it's a server-authoritative high-resolution timestamp delivered as a side effect of the list call we already make. No additional cost to compute the cache hit/miss.

---

## Options for how this changes seshctl

### Option A — Ship the recap (recommended)

Mirror the local `away_summary` slice. New code:

- `RemoteClaudeCodeFetcher.fetchLatestAssistantText(sessionId:)` — GET events?limit=10, walk newest-first, pick first `event_type=="assistant"`, return first `payload.message.content[type=="text"].text`'s first non-empty line.
- VM cache: `[String: (lastEventAt: Date, summary: String?)]`. Refresh loop iterates remote sessions; for any whose `last_event_at` ≠ cached value (or absent), kick off a fetch.
- Display: same `.awaySummary(text)` `PreviewContent` case the local side already wired up. `RemoteClaudeCodeSession+Display.previewContent(awaySummary:)` overload mirrors the local helper.

**Bandwidth:** ~17 KB per session per activity event. Idle sessions free.
**Code surface:** ~150 LoC + tests. Touches `RemoteClaudeCodeFetcher`, `SessionListViewModel`, `RemoteClaudeCodeSession+Display`, `RemoteClaudeCodeRowView`.
**Risk:** None of the events fields are documented. If Anthropic changes the shape, the row falls through to `title` — graceful degrade.

### Option B — Don't ship; lean on `worker_status` instead

Take a no-API-call route: render a short hint from `worker_status` ("Working…", "Idle — last activity 2h ago"). Reuses fields we already have.

**Pros:** Zero new bandwidth, zero new failure modes.
**Cons:** Synthetic, low information density. Doesn't tell the user *what* the agent did.

### Option C — Hybrid

Ship Option A as primary, fall back to a worker_status hint when the events fetch fails or returns no assistant block.

**Pros:** Best of both. Already roughly implied by graceful degrade.
**Cons:** Two display paths to maintain.

### Option D — Also model the unmodeled list fields

Independent of recap work: extend `RemoteClaudeCodeFetcher` to read `tags`, `external_metadata.current_branches`, `security_tier`, `config.sources[].revision`. Some interesting uses:

- `external_metadata.current_branches` → could replace the static `branches[0]` on line 2 with the *currently-checked-out* branch (which can differ if the agent has been switching branches).
- `tags` → potentially a filter/grouping signal in the future.
- `security_tier` → not user-facing today, but worth capturing for forward compatibility.

**Why separate from recap work:** orthogonal change set, different review surface. Worth scoping as its own pass once the recap is shipped.

### Option E — Wait for the API to grow a real recap field

Anthropic could add `last_recap` or similar to the list response at any time. If we ship Option A now and they ship a real field later, we'd swap the implementation behind the same cache map.

**Recommendation:** Don't wait. Option A is robust to that future and gives us the win now.

---

## Open questions that don't block a decision

1. **Streaming endpoint?** We skipped the DevTools capture. claude.ai/code's live UI might subscribe to a websocket or SSE endpoint that pushes new events. Worth a 5-min check at some point, but not required for the v1 — polling against the list endpoint already runs every 2s and gives us the activity signal we need.
2. **Rate limits.** No idea what's enforced. With Option A's bandwidth shape (sparse fetches keyed on activity), unlikely to hit limits in normal use, but should monitor.
3. **`assistant` content blocks beyond text.** Tool-use blocks, thinking blocks. Skip them — only `type == "text"` blocks become preview material.
4. **Long content.** The local-side `away_summary` is naturally one-paragraph (Claude Code writes them as terse status messages). Cloud assistant messages can be arbitrarily long. First-non-empty-line truncation already handles this — and the row's `.lineLimit(1)` enforces it visually — but the underlying string we cache could be a few KB. Worth trimming to a fixed character cap (e.g. 500) at scan time.

---

## Recommendation

**Option A** with `?limit=10` and a `last_event_at`-keyed in-memory cache. Mirrors the local side's pattern, costs ~17 KB per active session per refresh, falls through to `title` when the API has nothing useful, and slots into the `PreviewContent.awaySummary` case the local side already established.

If the user reaction is positive after a week, then take a pass at Option D (model the other unmodeled list fields) as a separate clean sweep.
