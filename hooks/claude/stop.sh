#!/bin/bash
# Claude Code Stop hook → seshctl-cli update (idle)
# Fires when Claude finishes responding.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
REPLY=$(echo "$PAYLOAD" | jq -r '.last_assistant_message // empty')
TRANSCRIPT_PATH=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')

LOG_DIR="$HOME/.local/share/seshctl/logs"
mkdir -p "$LOG_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%S') $SESSION_ID STOP" >> "$LOG_DIR/hooks.log"

# Clear any pending-question marker (see pre-tool-use.sh).
rm -f "$HOME/.local/share/seshctl/state/claude-awaiting-user-${SESSION_ID//[^A-Za-z0-9_-]/}"

ARGS=(--pid "$PPID" --tool claude --status idle)
if [ -n "$REPLY" ]; then
  ARGS+=(--reply "$REPLY")
fi
if [ -n "$TRANSCRIPT_PATH" ]; then
  ARGS+=(--transcript-path "$TRANSCRIPT_PATH")
fi

seshctl-cli update "${ARGS[@]}" > /dev/null 2>&1 &
