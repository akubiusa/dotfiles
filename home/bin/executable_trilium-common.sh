#!/usr/bin/env bash
# Trilium ETAPI 操作の共通関数群(trilium-upload.sh / trilium-search.sh から source される)。
# 単独では実行しない。

# ~/.env を読み込み、TRILIUM_HTTP_URL / TRILIUM_ETAPI_TOKEN の有無を検証する。
# 未設定の場合はエラーメッセージを出して終了する。
trilium_load_env() {
  # shellcheck source=/dev/null
  source "$HOME/.env"

  if [ -z "${TRILIUM_HTTP_URL:-}" ] || [ -z "${TRILIUM_ETAPI_TOKEN:-}" ]; then
    echo "ERROR: TRILIUM_HTTP_URL / TRILIUM_ETAPI_TOKEN must be set in ~/.env" >&2
    exit 1
  fi
}

# $1 (id) が Trilium noteId 形式(^[a-zA-Z0-9_]{4,32}$)を満たすか検証する。
# 満たさない場合は $2 (label) を含むエラーメッセージを出して終了する。
# 変換や切り詰めは一切行わない。
trilium_validate_id() {
  local id="$1"
  local label="$2"

  if ! [[ "$id" =~ ^[a-zA-Z0-9_]{4,32}$ ]]; then
    echo "ERROR: invalid $label: '$id' (must match ^[a-zA-Z0-9_]{4,32}\$)" >&2
    exit 1
  fi
}
