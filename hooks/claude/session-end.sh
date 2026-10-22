#!/bin/bash
# Claude Code SessionEnd hook → seshctl-cli end
# Fires when the session terminates.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')

LOG_DIR="$HOME/.local/share/seshctl/logs"
mkdir -p "$LOG_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%S') $SESSION_ID SESSION_END" >> "$LOG_DIR/hooks.log"

# Clear any pending-question marker (see pre-tool-use.sh).
rm -f "$HOME/.local/share/seshctl/state/claude-awaiting-user-${SESSION_ID//[^A-Za-z0-9_-]/}"

seshctl-cli end \
  --pid "$PPID" \
  --tool claude \
  > /dev/null 2>&1 &
