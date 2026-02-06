#!/bin/bash

# Claude Code PostToolUse hook として動作するスクリプト
# ツール使用後にキャンセルフラグを立て、待機中の通知をキャンセル

# データディレクトリの作成
DATA_DIR="$HOME/.claude/scripts/completion-notify/data"
mkdir -p "$DATA_DIR"

# 入力 JSON を読み取り
INPUT_JSON=$(cat)

# セッション ID を取得
SESSION_ID=$(echo "$INPUT_JSON" | jq -r '.session_id // empty')

# 通知キャンセルフラグを作成（既存の通知をキャンセル）
touch "$DATA_DIR/cancel-notify.flag"

# セッション固有のキャンセルフラグも作成（将来の拡張用）
if [[ -n "$SESSION_ID" ]]; then
  touch "$DATA_DIR/cancel-notify-${SESSION_ID}.flag"
fi

exit 0
