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

# $1 (topic) から folder_<正規化topic> の noteId を組み立て、既存なら再利用し、
# 存在しなければ $2 (folder_title) で "_share" 直下に新規作成する。
# 標準出力に noteId を1行出力する。$2 が空で新規作成が必要な場合はエラー終了する。
trilium_resolve_folder() {
  local topic="$1"
  local folder_title="$2"
  local normalized folder_id auth_header status payload

  normalized=$(printf '%s' "$topic" | tr '-' '_' | tr -cd 'a-zA-Z0-9_')
  folder_id="folder_${normalized}"
  trilium_validate_id "$folder_id" "folder noteId"

  auth_header="Authorization: $TRILIUM_ETAPI_TOKEN"
  status=$(curl -s -o /dev/null -w '%{http_code}' -H "$auth_header" \
    "$TRILIUM_HTTP_URL/etapi/notes/$folder_id")

  if [ "$status" = "200" ]; then
    printf '%s\n' "$folder_id"
    return 0
  elif [ "$status" != "404" ]; then
    echo "ERROR: unexpected status $status from Trilium existence check ($TRILIUM_HTTP_URL/etapi/notes/$folder_id)" >&2
    exit 1
  fi

  if [ -z "$folder_title" ]; then
    echo "ERROR: folder note $folder_id does not exist and no --folder-title was given" >&2
    exit 1
  fi

  payload=$(jq -n \
    --arg noteId "$folder_id" \
    --arg title "$folder_title" \
    '{parentNoteId: "_share", noteId: $noteId, title: $title, type: "text", content: ""}')
  curl -sf -X POST -H "$auth_header" -H "Content-Type: application/json" \
    --data "$payload" \
    "$TRILIUM_HTTP_URL/etapi/create-note" >/dev/null

  printf '%s\n' "$folder_id"
}

# $1 (noteId) と同じ $2 (topic) を持ち、$3 (docType) と異なる docType
# を持つ既存ノートを検索し、見つかった場合は双方に ~relatedTo を張る。
# 検索・属性付与の失敗はエラー終了させず、標準エラーに警告を出すのみに留める
# (アップロード自体を失敗させないベストエフォート動作のため)。
trilium_link_siblings() {
  local note_id="$1"
  local topic="$2"
  local doc_type="$3"
  local auth_header query response sibling_ids sibling_id rel_payload rev_payload

  auth_header="Authorization: $TRILIUM_ETAPI_TOKEN"
  query="#topic=${topic} #docType != ${doc_type}"

  if ! response=$(curl -sf -G -H "$auth_header" \
      --data-urlencode "search=$query" \
      --data-urlencode "ancestorNoteId=_share" \
      "$TRILIUM_HTTP_URL/etapi/notes"); then
    echo "WARNING: trilium_link_siblings: search request failed; skipping cross-link for $note_id" >&2
    return 0
  fi

  sibling_ids=$(printf '%s' "$response" | jq -r '.results[]?.noteId // empty')
  if [ -z "$sibling_ids" ]; then
    return 0
  fi

  while IFS= read -r sibling_id; do
    [ -z "$sibling_id" ] && continue

    rel_payload=$(jq -n --arg noteId "$note_id" --arg value "$sibling_id" \
      '{noteId: $noteId, type: "relation", name: "relatedTo", value: $value}')
    curl -sf -X POST -H "$auth_header" -H "Content-Type: application/json" \
      --data "$rel_payload" "$TRILIUM_HTTP_URL/etapi/attributes" >/dev/null \
      || echo "WARNING: trilium_link_siblings: failed to add relatedTo from $note_id to $sibling_id" >&2

    rev_payload=$(jq -n --arg noteId "$sibling_id" --arg value "$note_id" \
      '{noteId: $noteId, type: "relation", name: "relatedTo", value: $value}')
    curl -sf -X POST -H "$auth_header" -H "Content-Type: application/json" \
      --data "$rev_payload" "$TRILIUM_HTTP_URL/etapi/attributes" >/dev/null \
      || echo "WARNING: trilium_link_siblings: failed to add relatedTo from $sibling_id to $note_id" >&2
  done <<< "$sibling_ids"
}
