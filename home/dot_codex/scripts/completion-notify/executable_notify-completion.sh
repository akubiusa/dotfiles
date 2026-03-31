#!/bin/bash
# Codex CLI Stop hook で完了通知を送信する。

set -euo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=/dev/null
source ./.env

INPUT_JSON=$(cat)
CONTINUE_JSON='{"continue":true}'

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    printf '%s\n' "$CONTINUE_JSON"
    exit 0
fi

SESSION_ID=$(echo "$INPUT_JSON" | jq -r '.session_id // empty')
CWD_PATH=$(echo "$INPUT_JSON" | jq -r '.cwd // empty')
MODEL_NAME=$(echo "$INPUT_JSON" | jq -r '.model // empty')
LAST_ASSISTANT_MESSAGE=$(echo "$INPUT_JSON" | jq -r '.last_assistant_message // empty')

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
MACHINE_NAME=$(hostname)

FIELDS='[]'
FIELDS=$(echo "$FIELDS" | jq --arg name "📁 実行ディレクトリ" --arg value "$CWD_PATH" '. + [{"name": $name, "value": $value, "inline": true}]')
FIELDS=$(echo "$FIELDS" | jq --arg name "🆔 セッション ID" --arg value "$SESSION_ID" '. + [{"name": $name, "value": $value, "inline": true}]')
FIELDS=$(echo "$FIELDS" | jq --arg name "🧠 モデル" --arg value "$MODEL_NAME" '. + [{"name": $name, "value": $value, "inline": true}]')

if [[ -n "$LAST_ASSISTANT_MESSAGE" ]]; then
    FIELDS=$(echo "$FIELDS" | jq --arg name "🤖 最新の応答" --arg value "$LAST_ASSISTANT_MESSAGE" '. + [{"name": $name, "value": $value, "inline": false}]')
fi

CONTENT="Codex CLI Finished (${MACHINE_NAME})"
if [[ -n "${MENTION_USER_ID:-}" ]]; then
    CONTENT="<@${MENTION_USER_ID}> ${CONTENT}"
fi

PAYLOAD=$(jq -n \
    --arg content "$CONTENT" \
    --arg timestamp "$TIMESTAMP" \
    --argjson fields "$FIELDS" \
    '{
      content: $content,
      embeds: [{
        title: "Codex CLI セッション完了",
        color: 5763719,
        timestamp: $timestamp,
        fields: $fields
      }]
    }')

printf '%s\n' "$PAYLOAD" | "$(dirname "$0")/send-discord-notification.sh" >/dev/null 2>&1 &
printf '%s\n' "$CONTINUE_JSON"
exit 0
