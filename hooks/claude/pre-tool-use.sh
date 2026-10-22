#!/bin/bash
# Claude Code PreToolUse hook → seshctl-cli update (working)
# Fires before each tool call, ensuring the session shows as working.
# Uses --skip-git to avoid expensive git subprocess calls.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
TOOL_NAME=$(echo "$PAYLOAD" | jq -r '.tool_name // empty')
# Set only on tool calls made by a subagent; the main session's calls omit it.
AGENT_ID=$(echo "$PAYLOAD" | jq -r '.agent_id // empty')

LOG_DIR="$HOME/.local/share/seshctl/logs"
mkdir -p "$LOG_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%S') $SESSION_ID PRE_TOOL_USE $TOOL_NAME${AGENT_ID:+ agent=$AGENT_ID}" >> "$LOG_DIR/hooks.log"

# Subagent tool calls share the parent's session and PID. The parent's own
# Agent call already marked the session working, so skip them — otherwise a
# background subagent flips a waiting session (e.g. an open question) back
# to working.
if [ -n "$AGENT_ID" ]; then
  exit 0
fi

# These tools block on the user, so show waiting immediately rather than
# working until Claude Code's Notification hook fires seconds later.
STATUS=working
case "$TOOL_NAME" in
  AskUserQuestion|ExitPlanMode) STATUS=waiting ;;
esac

seshctl-cli update \
  --pid "$PPID" \
  --tool claude \
  --status "$STATUS" \
  --skip-git \
  > /dev/null 2>&1 &
