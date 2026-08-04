#!/bin/bash
# Claude Code SessionStart hook → seshctl-cli start
# Reads JSON payload from stdin, extracts session_id, cwd, and transcript_path.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
CWD=$(echo "$PAYLOAD" | jq -r '.cwd')
TRANSCRIPT_PATH=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')

LOG_DIR="$HOME/.local/share/seshctl/logs"
mkdir -p "$LOG_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%S') $SESSION_ID SESSION_START" >> "$LOG_DIR/hooks.log"

ARGS=(--tool claude --dir "$CWD" --pid "$PPID" --conversation-id "$SESSION_ID")
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
fi
# No Ghostty branch: the app matches Ghostty surfaces by TTY, derived from the
# recorded PID at focus time. Asking AppleScript for the focused terminal here
# guessed that the starting session is frontmost (wrong for a background tab or
# split), cost an Automation prompt during hook execution, and went stale on
# resume.

seshctl-cli start "${ARGS[@]}" > /dev/null 2>&1 &
