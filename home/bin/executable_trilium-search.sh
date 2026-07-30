#!/usr/bin/env bash
# Trilium 上で #topic ラベルからドキュメントを検索する。
# 使い方: trilium-search.sh <topic>
# ヒットしたノードをタイトルと共有 URL の1行ずつ標準出力する。0件の場合は
# 「該当なし」を標準出力し、終了コード0で終える(該当なしはエラーではない)。
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$script_dir/trilium-common.sh"

if [ "$#" -ne 1 ]; then
  echo "Usage: trilium-search.sh <topic>" >&2
  exit 1
fi

topic="$1"

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required but not installed" >&2
    exit 1
  fi
done

trilium_load_env
auth_header="Authorization: $TRILIUM_ETAPI_TOKEN"

fetch_results() {
  local query="$1"
  curl -sf -G -H "$auth_header" \
    --data-urlencode "search=$query" \
    --data-urlencode "ancestorNoteId=_share" \
    "$TRILIUM_HTTP_URL/etapi/notes"
}

response=$(fetch_results "#topic=${topic}")
hits=$(printf '%s' "$response" | jq -r '.results | length')

if [ "$hits" -eq 0 ]; then
  response=$(fetch_results "#topic *=* ${topic}")
  hits=$(printf '%s' "$response" | jq -r '.results | length')
fi

if [ "$hits" -eq 0 ]; then
  echo "該当なし"
  exit 0
fi

printf '%s' "$response" | jq -r --arg base "$TRILIUM_HTTP_URL" \
  '.results[] | "\(.title)\t\($base)/share/\(.noteId)"'
