#!/bin/bash
# chezmoi の自動更新スクリプト
# 24 時間以内に実行済みの場合はスキップする

set -euo pipefail

CACHE_DIR="$HOME/.cache/chezmoi-update"
TIMESTAMP_FILE="$CACHE_DIR/last-update"
CHEZMOI_BIN="$HOME/.local/bin/chezmoi"
LEGACY_CHEZMOI_BIN="$HOME/bin/chezmoi"

mkdir -p "$CACHE_DIR"

if [[ -f "$TIMESTAMP_FILE" ]]; then
  last_update=$(cat "$TIMESTAMP_FILE" 2>/dev/null || echo "")
  # 非数値・空の場合は 0 扱いにして算術展開エラーを防ぐ
  [[ "$last_update" =~ ^[0-9]+$ ]] || last_update=0
  elapsed=$(( $(date +%s) - last_update ))
  if [[ $elapsed -lt 86400 ]]; then
    exit 0
  fi
fi

# chezmoi の公式インストーラで ~/.local/bin の単一バイナリを更新する。
installer=$(curl -fsSL https://get.chezmoi.io)
sh -c "$installer" -- -b "$HOME/.local/bin"

# インストーラ経由の暗黙実行に依存せず、管理対象のバイナリを明示して更新する。
"$CHEZMOI_BIN" update

# 旧 updater が作成した ~/bin/chezmoi は、正常更新後に削除して二重管理を解消する。
rm -f -- "$LEGACY_CHEZMOI_BIN"

date +%s > "$TIMESTAMP_FILE"
