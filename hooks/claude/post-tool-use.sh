#!/bin/bash
# Claude Code PostToolUse hook → seshctl-cli update (working)
# Registered only for the tools that block on the user (see the matcher in
# FirstLaunchInstaller). Once the user answers, Claude resumes working.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
TOOL_NAME=$(echo "$PAYLOAD" | jq -r '.tool_name // empty')

case "$TOOL_NAME" in
  AskUserQuestion|ExitPlanMode) ;;
  *) exit 0 ;;
esac

LOG_DIR="$HOME/.local/share/seshctl/logs"
mkdir -p "$LOG_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%S') $SESSION_ID POST_TOOL_USE $TOOL_NAME" >> "$LOG_DIR/hooks.log"

rm -f "$HOME/.local/share/seshctl/state/claude-awaiting-user-${SESSION_ID//[^A-Za-z0-9_-]/}"

seshctl-cli update \
  --pid "$PPID" \
  --tool claude \
  --status working \
  --skip-git \
  > /dev/null 2>&1 &
