#!/bin/bash
# Send a Discord notification when a Codex turn stops.

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
CWD_PATH=$(jq -r '.cwd // "unknown"' <<<"$INPUT_JSON")
MESSAGE=$(jq -r '.last_assistant_message // ""' <<<"$INPUT_JSON")
MESSAGE=${MESSAGE:0:1500}
rm -f "$HOME/.codex/scripts/completion-notify/data/pending-permission-${SESSION_ID}"
MACHINE_NAME=$(hostname)
CONTENT="Codex CLI finished (${MACHINE_NAME})\nSession: ${SESSION_ID}\nDirectory: ${CWD_PATH}"
if [[ -n "${MENTION_USER_ID:-}" ]]; then
    CONTENT="<@${MENTION_USER_ID}> ${CONTENT}"
fi

PAYLOAD=$(jq -n --arg content "$CONTENT" --arg message "$MESSAGE" '{content: $content, embeds: (if $message == "" then [] else [{title: "Final response", description: $message, color: 5763719}] end)}')
printf '%s\n' "$PAYLOAD" | "$SCRIPT_DIR/send-discord-notification.sh" >/dev/null 2>&1 &

# Stop hooks require JSON when they exit successfully.
printf '%s\n' '{}'
