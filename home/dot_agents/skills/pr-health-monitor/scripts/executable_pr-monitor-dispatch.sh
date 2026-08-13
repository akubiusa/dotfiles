#!/bin/bash

# PR event を登録済み Codex pane へ固定形式で配送する。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_HELPER="$SCRIPT_DIR/pr-monitor-state.sh"
[[ -x "$STATE_HELPER" ]] || STATE_HELPER="$SCRIPT_DIR/executable_pr-monitor-state.sh"

usage() {
    echo "Usage: $0 --pr-url URL" >&2
    exit 1
}

PR_URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr-url)
            PR_URL="${2:-}"
            shift
            ;;
        *) usage ;;
    esac
    shift
done

[[ "$PR_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || usage
[[ -x "$STATE_HELPER" ]] || { echo "Error: Missing PR monitor state helper" >&2; exit 1; }

STATE=$($STATE_HELPER show --pr-url "$PR_URL")
PANE=$(jq -r '.runtime.pane // empty' <<< "$STATE")
SESSION_ID=$(jq -r '.runtime.session_id // empty' <<< "$STATE")
STATUS=$(jq -r '.runtime.status // empty' <<< "$STATE")
[[ "$PANE" =~ ^%[0-9]+$ && "$SESSION_ID" =~ ^[A-Za-z0-9_.-]+$ && "$STATUS" == "ready" ]] || exit 0

CURRENT_PANE=$(tmux display-message -p -t "$PANE" '#{pane_id}' 2>/dev/null || true)
[[ "$CURRENT_PANE" == "$PANE" ]] || exit 0

EVENT=$(jq -r '
    if .events.close != null and .events.close.actions.cleanup.status == "pending" then
        "close"
    else
        .events | to_entries[] | select(.key != "close" and .value != null and .value.status == "pending") | .key
    end
' <<< "$STATE" | head -n 1)
[[ "$EVENT" =~ ^(close|ci_failure|conflict|copilot_review)$ ]] || exit 0
EVENT_ID=$(jq -r --arg event "$EVENT" 'if $event == "close" then .events.close.id // "close:1" else .events[$event].id // ($event + ":1") end' <<< "$STATE")
[[ "$EVENT_ID" =~ ^(close|ci_failure|conflict|copilot_review):[1-9][0-9]*$ ]] || exit 0
PROMPT="\$resume-pr-monitor $PR_URL --event-id $EVENT_ID"

tmux send-keys -t "$PANE" -l -- "$PROMPT"
tmux send-keys -t "$PANE" Enter
