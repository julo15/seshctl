# Title suggestions on `t`

> Revised: one suggestion with y/n instead of three to pick from (user call, after trying it).

User-initiated retitling, built from #69's ideas (credit Tom for the output
cleanup and CLI resolution).

## Behavior

- `t` on a local Claude or Codex row with a conversation id asks Haiku for
  a title describing what the session is doing **now**. The row shows
  "Titling…" (~3.5s, measured) and the user can keep navigating.
- When it arrives, the row shows it with a hint. `y` uses it (only when
  that row is selected), `n` or Esc declines, `t` asks again.
- An accepted title is stored per conversation (`conversation_id` + tool), so it
  survives resume, the `c` view and app restarts. It overrides Claude's
  `ai-title` until the user accepts another.
- No automatic titling: Claude's own `ai-title` covers the opening.

## Material (recency-biased)

- The last 10 user prompts (each trimmed), the latest assistant reply
  (trimmed), and the current title as background.
- The prompt says the session may have moved through several tasks and to
  title only the current one.

## Run

`claude -p --model haiku --setting-sources project --no-session-persistence`
from a neutral temp directory: loads no user settings (so no hooks, no stray
rows) and saves no session. Verified: 68 rows before and after. Also sets
`SESHCTL_INTERNAL_SESSION=1` as a guard the hooks don't read yet. Run off the
main actor with a 45s timeout. Failures turn the row's state into a short
"Couldn't title" note.

## Pieces

- `SeshctlCore/TitleSuggester.swift`: material, prompt, output parsing
  (escape stripping and cleanup from #69), CLI resolution, `generate`.
- `ShellRunner.run` gains `currentDirectory`.
- `Database`: migration `v15_create_conversation_titles`
  (`conversation_id`, `tool`, `title`, `updated_at`, PK on the first two),
  `setConversationTitle`, `conversationTitles()`.
- `SessionListViewModel`: `titleSuggestionsById` state (`loading` /
  `ready([String])` / `failed`), `requestTitleSuggestions()`,
  `acceptTitleSuggestion()`, `dismissTitleSuggestions()`. Stored titles
  override scanned ones in `titlesById`. Generator injected for tests.
- `SessionRowView`: a line under the row content for the state.
- `AppDelegate`: `t`, `y`, `n`, Esc.
- Help popover, README keys, AGENTS.md section.

## Tests

Suggester parsing and material; DB round trip and override; VM flow with a
stub generator (loading → ready → accept persists and overrides; decline discards;
accept ignored on other rows; failure state).
