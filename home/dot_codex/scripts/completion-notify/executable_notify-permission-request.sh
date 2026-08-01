#!/bin/bash
# Notify after a Codex approval request remains pending for the configured delay.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
else
    source "$SCRIPT_DIR/dot_env"
fi

INPUT_JSON=$(cat)
SESSION_ID=$(jq -r '.session_id // "unknown"' <<<"$INPUT_JSON")
TOOL_NAME=$(jq -r '.tool_name // "unknown"' <<<"$INPUT_JSON")
TOOL_INPUT=$(jq -c '.tool_input // {}' <<<"$INPUT_JSON")
DATA_DIR="$HOME/.codex/scripts/completion-notify/data"
PENDING_FILE="$DATA_DIR/pending-permission-${SESSION_ID}"
mkdir -p "$DATA_DIR"
touch "$PENDING_FILE"

(
    sleep "${CODEX_NOTIFICATION_DELAY_SECONDS:-60}"
    [[ -f "$PENDING_FILE" ]] || exit 0
    rm -f "$PENDING_FILE"

    CONTENT="Codex CLI approval needed\nTool: ${TOOL_NAME}\nSession: ${SESSION_ID}"
    if [[ -n "${MENTION_USER_ID:-}" ]]; then
        CONTENT="<@${MENTION_USER_ID}> ${CONTENT}"
    fi
    PAYLOAD=$(jq -n --arg content "$CONTENT" --arg input "$TOOL_INPUT" '{content: $content, embeds: [{title: "Requested input", description: $input, color: 16753920}]}')
    printf '%s\n' "$PAYLOAD" | "$SCRIPT_DIR/send-discord-notification.sh" >/dev/null 2>&1
) >/dev/null 2>&1 &
