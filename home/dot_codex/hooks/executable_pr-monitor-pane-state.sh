#!/bin/bash

# Codex lifecycle event を、同じ tmux pane に登録された PR monitor へ反映する。
set -euo pipefail

STATUS="${1:-}"
[[ "$STATUS" =~ ^(busy|ready|approval_pending|stopped)$ ]] || exit 0
[[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] || exit 0

INPUT=$(cat)
SESSION_ID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null || true)
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 0

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$STATE_HOME/codex-pr-monitor"
HELPER="$HOME/.agents/skills/pr-health-monitor/scripts/pr-monitor-state.sh"
[[ -x "$HELPER" ]] || exit 0

shopt -s nullglob
for state_file in "$STATE_DIR"/*.json; do
    pane=$(jq -r '.runtime.pane // empty' "$state_file" 2>/dev/null || true)
    nonce=$(jq -r '.runtime.nonce // empty' "$state_file" 2>/dev/null || true)
    url=$(jq -r '.pr.url // empty' "$state_file" 2>/dev/null || true)
    [[ "$pane" == "$TMUX_PANE" && "$nonce" =~ ^[A-Za-z0-9_.-]{16,}$ && -n "$url" ]] || continue
    "$HELPER" pane-status --pr-url "$url" --nonce "$nonce" --session-id "$SESSION_ID" --status "$STATUS" >/dev/null 2>&1 || true
done
