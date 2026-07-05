#!/bin/bash

# ユーザーが明示的にレビュー未解決警告への対応を拒否した際、
# 同一セッション内で同じ PR について再警告しないよう記録する。
# require-review-thread-fixes.sh の Stop hook から参照される。

PR_NUMBER="${1:?Usage: mark-review-declined.sh <PR_NUMBER>}"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:?CLAUDE_CODE_SESSION_ID is not set}"
DATA_DIR="$HOME/.claude/data"
DECLINE_FILE="$DATA_DIR/review-declined-${SESSION_ID}.json"

mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"

EXISTING=$(cat "$DECLINE_FILE" 2>/dev/null || echo '{"declined_prs":[]}')
jq --argjson pr "$PR_NUMBER" '.declined_prs |= (. + [$pr] | unique)' <<< "$EXISTING" \
    > "$DECLINE_FILE"
chmod 600 "$DECLINE_FILE"

echo "PR #${PR_NUMBER} marked as declined for this session (${SESSION_ID})."
