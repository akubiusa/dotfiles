#!/bin/bash

# Claude Code PostToolUse hook として動作するスクリプト
# ツール使用後にキャンセルフラグを立て、待機中の通知をキャンセル

# データディレクトリの作成
DATA_DIR="$HOME/.claude/scripts/completion-notify/data"
mkdir -p "$DATA_DIR"

# 入力 JSON を読み取り
INPUT_JSON=$(cat)

# デバッグログ
echo "$(date -Iseconds) notify-post-tool-use.sh called" >> "$DATA_DIR/hook-debug.log"

# セッション ID とツール名を取得
SESSION_ID=$(echo "$INPUT_JSON" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT_JSON" | jq -r '.tool_name // empty')

# デバッグログ: tool_name を記録
echo "$(date -Iseconds) PostToolUse: TOOL_NAME=$TOOL_NAME, SESSION_ID=$SESSION_ID" >> "$DATA_DIR/hook-debug.log"

# セッション固有のキャンセルフラグを作成（優先）
if [[ -n "$SESSION_ID" ]]; then
  touch "$DATA_DIR/cancel-notify-${SESSION_ID}.flag"
fi

# グローバルキャンセルフラグも作成（SESSION_ID が取得できない場合のフォールバック）
touch "$DATA_DIR/cancel-notify.flag"

# AskUserQuestion の PostToolUse の場合、表示中フラグを削除
if [[ "$TOOL_NAME" == "AskUserQuestion" && -n "$SESSION_ID" ]]; then
  rm -f "$DATA_DIR/askuserquestion-active-${SESSION_ID}.flag" 2>/dev/null
  echo "$(date -Iseconds) Removed askuserquestion-active flag" >> "$DATA_DIR/hook-debug.log"
fi

exit 0
