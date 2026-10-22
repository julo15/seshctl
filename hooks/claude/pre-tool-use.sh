#!/bin/bash
# Claude Code PreToolUse hook → seshctl-cli update (working / waiting)
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

# Present while a blocking tool (below) waits on the user. Cleared by
# post-tool-use.sh once answered, and by stop / user-prompt / session-end.
STATE_DIR="$HOME/.local/share/seshctl/state"
AWAITING_MARKER="$STATE_DIR/claude-awaiting-user-${SESSION_ID//[^A-Za-z0-9_-]/}"

case "$TOOL_NAME" in
  # Tools that block on the user: show waiting immediately rather than
  # working until Claude Code's Notification hook fires seconds later.
  AskUserQuestion|ExitPlanMode)
    STATUS=waiting
    mkdir -p "$STATE_DIR"
    touch "$AWAITING_MARKER"
    ;;
  *)
    STATUS=working
    if [ -e "$AWAITING_MARKER" ]; then
      # Subagent tool calls share the parent's session and PID. A background
      # subagent must not flip a session waiting on the user back to working.
      if [ -n "$AGENT_ID" ]; then
        exit 0
      fi
      # The main session moved on, so the question was resolved.
      rm -f "$AWAITING_MARKER"
    fi
    ;;
esac

seshctl-cli update \
  --pid "$PPID" \
  --tool claude \
  --status "$STATUS" \
  --skip-git \
  > /dev/null 2>&1 &
