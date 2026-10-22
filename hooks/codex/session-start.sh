#!/bin/bash
# Codex SessionStart hook → seshctl-cli start
# Reads JSON payload from stdin, extracts session_id, cwd, and transcript_path.
set -euo pipefail

PAYLOAD=$(cat)
CWD=$(echo "$PAYLOAD" | jq -r '.cwd')
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
TRANSCRIPT_PATH=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')

ARGS=(--tool codex --dir "$CWD" --pid "$PPID" --conversation-id "$SESSION_ID")
if [ -n "$TRANSCRIPT_PATH" ]; then
  ARGS+=(--transcript-path "$TRANSCRIPT_PATH")
fi

# Capture cmux workspace ID if running inside cmux.
# (cmux sets TERM_PROGRAM=ghostty because it embeds libghostty, so check this first.)
if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then
    ARGS+=(--window-id "$CMUX_WORKSPACE_ID|$CMUX_SURFACE_ID")
  else
    ARGS+=(--window-id "$CMUX_WORKSPACE_ID")
  fi
elif [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
  # Capture Ghostty terminal ID if running inside Ghostty. The app matches
  # Ghostty surfaces by TTY first, but stable Ghostty (1.3.1) has no `tty`
  # scripting property, so this ID is the only precise match there. Drop it
  # once a stable Ghostty release exposes `tty`.
  GHOSTTY_ID=$(osascript -e '
    tell application "Ghostty"
      try
        set trm to focused terminal of selected tab of front window
        return id of trm
      end try
    end tell
  ' 2>/dev/null || true)
  if [ -n "$GHOSTTY_ID" ]; then
    ARGS+=(--window-id "$GHOSTTY_ID")
  fi
fi

seshctl-cli start "${ARGS[@]}" > /dev/null 2>&1
