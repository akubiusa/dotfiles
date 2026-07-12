#!/usr/bin/env bash
# Trilium へドキュメントをアップロードする(ETAPI 経由、pandoc で Markdown → HTML 変換)。
# 使い方: trilium-upload.sh <file-path> <slug> <title>
# 成功時は標準出力の最終行に共有 URL を出力する。
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: trilium-upload.sh <file-path> <slug> <title>" >&2
  exit 1
fi

file="$1"
slug="$2"
title="$3"

if [ ! -f "$file" ]; then
  echo "ERROR: file not found: $file" >&2
  exit 1
fi

for cmd in pandoc curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required but not installed" >&2
    exit 1
  fi
done

# ~/.env を読み込む(completion-notify 配下のスクリプト群と同じパターン)。
# shellcheck source=/dev/null
source "$HOME/.env"

if [ -z "${TRILIUM_HTTP_URL:-}" ] || [ -z "${TRILIUM_ETAPI_TOKEN:-}" ]; then
  echo "ERROR: TRILIUM_HTTP_URL / TRILIUM_ETAPI_TOKEN must be set in ~/.env" >&2
  exit 1
fi

# slug を ETAPI の noteId 形式([a-zA-Z0-9_]{4,32})に正規化する。
note_id=$(printf '%s' "$slug" | tr '-' '_' | tr -cd 'a-zA-Z0-9_' | cut -c1-32)
if [ "${#note_id}" -lt 4 ]; then
  echo "ERROR: slug too short after normalization to a valid Trilium noteId: $slug" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

html_file="$tmpdir/content.html"
pandoc "$file" -o "$html_file"

auth_header="Authorization: $TRILIUM_ETAPI_TOKEN"

# 既存ノートかどうかを確認する。
get_status=$(curl -s -o /dev/null -w '%{http_code}' -H "$auth_header" \
  "$TRILIUM_HTTP_URL/etapi/notes/$note_id")

if [ "$get_status" = "200" ]; then
  # 既存ノートを更新: title と content の両方を上書きする。
  title_payload=$(jq -n --arg title "$title" '{title: $title}')
  curl -sf -X PATCH -H "$auth_header" -H "Content-Type: application/json" \
    --data "$title_payload" \
    "$TRILIUM_HTTP_URL/etapi/notes/$note_id" >/dev/null
  curl -sf -X PUT -H "$auth_header" -H "Content-Type: text/plain" \
    --data-binary "@$html_file" \
    "$TRILIUM_HTTP_URL/etapi/notes/$note_id/content" >/dev/null
else
  # 新規作成: "_share" の直下に、noteId を明示指定して作成する。
  # → "_share" の子孫に配置されたノートは自動的に共有(公開閲覧可能)になる。
  payload=$(jq -n \
    --arg noteId "$note_id" \
    --arg title "$title" \
    --arg content "$(cat "$html_file")" \
    '{parentNoteId: "_share", noteId: $noteId, title: $title, type: "text", content: $content}')
  curl -sf -X POST -H "$auth_header" -H "Content-Type: application/json" \
    --data "$payload" \
    "$TRILIUM_HTTP_URL/etapi/create-note" >/dev/null
fi

echo "$TRILIUM_HTTP_URL/share/$note_id"
