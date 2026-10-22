#!/bin/bash
# Claude Code UserPromptSubmit hook → seshctl-cli update (working)
# Reads JSON payload from stdin, extracts the user's prompt.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
PROMPT=$(echo "$PAYLOAD" | jq -r '.prompt // empty')
CWD=$(echo "$PAYLOAD" | jq -r '.cwd')
TRANSCRIPT_PATH=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')

LOG_DIR="$HOME/.local/share/seshctl/logs"
mkdir -p "$LOG_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%S') $SESSION_ID USER_PROMPT_SUBMIT" >> "$LOG_DIR/hooks.log"

# Clear any pending-question marker (see pre-tool-use.sh).
rm -f "$HOME/.local/share/seshctl/state/claude-awaiting-user-${SESSION_ID//[^A-Za-z0-9_-]/}"

ARGS=(--pid "$PPID" --tool claude --status working --dir "$CWD")
if [ -n "$PROMPT" ]; then
  ARGS+=(--ask "$PROMPT")
fi
if [ -n "$TRANSCRIPT_PATH" ]; then
  ARGS+=(--transcript-path "$TRANSCRIPT_PATH")
fi

seshctl-cli update "${ARGS[@]}" > /dev/null 2>&1 &
