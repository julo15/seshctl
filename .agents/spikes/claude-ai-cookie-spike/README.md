# Claude.ai Cookie Spike

Throwaway SwiftPM executable for poking at the claude.ai internal API
(`/v1/code/...`) with cookies captured from a real WKWebView login.

## Modes

Originally answered the two P0 assumptions in
`.agents/plans/2026-04-20-0928-remote-claude-code-sessions.md` (cookie capture
and 200 from the list endpoint — both ✅, already folded back into the plan).

It's now also doing a **remote-session-fields sweep** for the away-summary
follow-up: dump the full list response (every field, including ones we don't
model in `RemoteClaudeCodeFetcher`), then blind-probe a set of candidate
per-session detail endpoints to discover what extra data the cloud surfaces.

## Run

```
cd .agents/spikes/claude-ai-cookie-spike
swift run CookieSpike [extraURL ...]
```

A WKWebView window opens at `claude.ai/login`. Sign in normally
(Google OAuth or magic link); WKWebsiteDataStore persists between runs so
subsequent invocations skip the manual login if cookies are still valid.
After login is detected, the spike:

1. Lists the cookies and confirms `sessionKey` + `sessionKeyLC` are present.
2. Hits `/v1/code/sessions?limit=50` and saves the pretty-printed JSON to
   `out/01_list.json`. Prints the top-level keys so you can spot unmodeled
   fields at a glance.
3. Parses the first 3 session ids and blind-probes candidate detail paths
   for each (`/v1/code/sessions/<id>`, `/messages`, `/turns`, `/events`,
   `/history`, `/outcomes`, `/files`, `/summary`). Each response is saved to
   `out/<NN>_<sanitized-path>.json` with the status code logged.
4. Replays any extra URLs passed on the command line — useful when DevTools
   surfaces an endpoint that wasn't in the guess list.

### DevTools companion

The guess list is just guesses. The reliable discovery path is to open
`https://claude.ai/code` in a browser, open DevTools → Network → XHR/Fetch,
click into a session, and copy any `claude.ai/v1/...` URLs that fire. Pass
them as extra args:

```
swift run CookieSpike \
  https://claude.ai/v1/code/sessions/cse_xxx/whatever \
  https://claude.ai/v1/code/sessions/cse_xxx/whatever2
```

The spike replays them with the same Cookie / Origin / Referer / UA / beta
headers and dumps the body alongside the blind-probe results.

## Output

All responses land in `out/` (gitignored). Useful follow-ups:

```
jq 'keys' out/01_list.json
jq '.data[0] | keys' out/01_list.json     # full per-session shape
grep -l '"summary"' out/*.json           # which endpoints carry a summary field
```

## Cleanup

Throwaway directory. Delete with `trash .agents/spikes/claude-ai-cookie-spike/`
once the findings are folded back into a plan or the codebase.
