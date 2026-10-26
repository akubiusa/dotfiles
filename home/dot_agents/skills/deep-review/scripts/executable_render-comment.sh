#!/usr/bin/env bash
# ledger から開発者向け PR コメント本文を生成して stdout に出す。
#   render-comment.sh <session> <repo-dir>
#   render-comment.sh --update <session> <repo-dir> <existing-body-file>
# コード引用は ledger の head SHA のファイルから git show で取得する。

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then UPDATE=1; shift; fi
if [[ $UPDATE -eq 1 ]]; then
  [[ $# -eq 3 ]] || die "usage: render-comment.sh --update <session> <repo-dir> <existing-body-file>"
  EXISTING="$3"
  [[ -f "$EXISTING" ]] || die "existing body file not found"
  grep -qxF '<!-- deep-review:v1 -->' "$EXISTING" || die "existing body has no deep-review marker"
else
  [[ $# -eq 2 ]] || die "usage: render-comment.sh <session> <repo-dir>"
fi
SESSION="$1"
REPO_DIR="$2"
[[ "$SESSION" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid session id"
LEDGER="${DEEP_REVIEW_DATA_DIR:-$HOME/.claude/data}/deep-review-ledger-${SESSION}.json"
[[ -f "$LEDGER" ]] || die "ledger not found: $LEDGER"

SHA=$(jq -r '.baseline.head_sha' "$LEDGER")
REPO=$(jq -r '.target.repo' "$LEDGER")
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "head_sha must be a full 40-char SHA"

# 半角ゼロ幅スペース (U+200B) を "#数字" の間に挟み、自動リンク化を防ぐ
ZW=$(printf '\xe2\x80\x8b')
prose() {
  local s=${1//$'\r'/}
  s=${s//$'\n'/<br>}
  printf '%s' "$s" | sed -E "s/#([0-9])/#${ZW}\1/g"
}
cell() { local s; s=$(prose "$1"); printf '%s' "${s//|/\\|}"; }

# 指摘 1 件の詳細ブロックを出力する: id json
render_block() {
  local id=$1 j=$2 key path line end quote maxbt n fence
  key=$(jq -r '.key' <<<"$j"); path=$(jq -r '.path' <<<"$j")
  line=$(jq -r '.line // empty' <<<"$j")
  [[ -n "$line" ]] || die "finding $key has no line"
  end=$(jq -r '.detail.line_end // .line' <<<"$j")
  # line / end は sed のアドレスに使うため、整数以外 (sed の e コマンド注入など) は拒否する
  [[ "$line" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || die "finding $key has non-integer line range: $line-$end"
  (( end >= line )) || die "finding $key has line_end < line: $line-$end"
  quote=$(git -C "$REPO_DIR" show "$SHA:$path" | sed -n "${line},${end}p") || die "cannot read $SHA:$path"
  [[ -n "$quote" ]] || die "empty quote for $path:$line-$end"
  # 引用中の最長バッククォート連続より長いフェンスにする
  maxbt=$(printf '%s' "$quote" | grep -o '`\+' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  n=$(( maxbt + 1 )); [[ $n -ge 3 ]] || n=3
  fence=$(printf '`%.0s' $(seq "$n"))
  printf '<!-- finding:%s:%s -->\n' "$key" "$path"
  printf '#### 指摘%s: %s\n\n' "$id" "$(prose "$(jq -r '.title' <<<"$j")")"
  printf -- '- 発生条件: %s\n' "$(prose "$(jq -r '.detail.condition // ""' <<<"$j")")"
  printf -- '- 影響: %s\n' "$(prose "$(jq -r '.detail.impact // ""' <<<"$j")")"
  printf -- '- 修正方針: %s\n' "$(prose "$(jq -r '.detail.fix_plan // ""' <<<"$j")")"
  printf -- '- 該当箇所: [%s#L%s-L%s](https://github.com/%s/blob/%s/%s#L%s-L%s)\n\n' \
    "$path" "$line" "$end" "$REPO" "$SHA" "$path" "$line" "$end"
  printf '%s\n%s\n%s\n' "$fence" "$quote" "$fence"
  printf '<!-- /finding -->\n'
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 既存本文の finding ブロックを切り出す (解消済み節内かどうかも記録)。
# 引用中の ### 行や finding 終端マーカー風の行を誤認しないよう、ブロック内ではフェンスを追跡する。
declare -A EXFILE EXID EXRES
if [[ $UPDATE -eq 1 ]]; then
  awk -v d="$TMP" '
    function bt(s) { return match(s, /^`+/) ? RLENGTH : 0 }
    inb {
      print > f
      if (fence) { if (bt($0) >= flen && bt($0) == length($0)) fence = 0; next }
      if (bt($0) >= 3) { fence = 1; flen = bt($0); next }
      if ($0 ~ /^<!-- \/finding -->/) { close(f); print n > (r ? d "/res" : d "/act"); inb = 0 }
      next
    }
    /^### / { res = ($0 ~ /^### 解消済み/) }
    /^<!-- finding:/ { n++; f = d "/b." n; inb = 1; r = res; fence = 0; print > f }
  ' "$EXISTING"
  for f in "$TMP"/b.*; do
    [[ -e "$f" ]] || continue
    m=$(head -n 1 "$f")
    kp=${m#'<!-- finding:'}; kp=${kp%' -->'}
    id=$(grep -m1 -oE '^#### 指摘[0-9]+' "$f" | grep -oE '[0-9]+$') || die "existing block without heading: $kp"
    EXFILE[$kp]=$f; EXID[$kp]=$id
    if grep -qxF "${f##*/b.}" "$TMP/res" 2>/dev/null; then EXRES[$kp]=1; fi
  done
fi

declare -A USED LEDGERKP TBL BODY CNT
for s in B F R; do TBL[$s]=""; BODY[$s]=""; CNT[$s]=0; done
for id in "${EXID[@]}"; do USED[$id]=1; done

add_active() {
  local sec=$1 j=$2 kp=$3 id lid
  if [[ -n "${EXFILE[$kp]:-}" ]]; then
    id=${EXID[$kp]}
    BODY[$sec]+="$(cat "${EXFILE[$kp]}")"$'\n\n'
  else
    lid=$(jq -r '.id' <<<"$j"); id=$lid
    while [[ -n "${USED[$id]:-}" ]]; do id=$(( id + 1 )); done
    USED[$id]=1
    BODY[$sec]+="$(render_block "$id" "$j")"$'\n\n'
  fi
  TBL[$sec]+="| 指摘${id} | $(cell "$(jq -r '.title' <<<"$j")") | $(cell "$(jq -r '"`" + .path + ":" + (.line | tostring) + "`"' <<<"$j")") |"$'\n'
  CNT[$sec]=$(( CNT[$sec] + 1 ))
}

jq -e '.findings | type == "array"' "$LEDGER" >/dev/null || die "ledger has no findings array"
FINDINGS=$(jq -c '.findings[]' "$LEDGER") || die "cannot read findings from ledger"

while IFS= read -r j; do
  [[ -n "$j" ]] || continue
  kp="$(jq -r '.key' <<<"$j"):$(jq -r '.path' <<<"$j")"
  LEDGERKP[$kp]=1
  status=$(jq -r '.status' <<<"$j"); cls=$(jq -r '.class' <<<"$j")
  if [[ "$status" == "open" || "$status" == "deferred" ]]; then
    case "$cls" in
      merge-blocker) add_active B "$j" "$kp" ;;
      follow-up) add_active F "$j" "$kp" ;;
    esac
  elif [[ $UPDATE -eq 1 && -n "${EXFILE[$kp]:-}" && ( "$status" == "fixed" || "$status" == "false_positive" ) ]]; then
    BODY[R]+="$(cat "${EXFILE[$kp]}")"$'\n\n'
    CNT[R]=$(( CNT[R] + 1 ))
  fi
done <<<"$FINDINGS"

# ledger に無い解消済み節の既存ブロックはそのまま保持する
for kp in "${!EXRES[@]}"; do
  [[ -z "${LEDGERKP[$kp]:-}" ]] || continue
  BODY[R]+="$(cat "${EXFILE[$kp]}")"$'\n\n'
  CNT[R]=$(( CNT[R] + 1 ))
done

section() {
  local sec=$1 title=$2
  [[ ${CNT[$sec]} -gt 0 ]] || return 0
  printf '### %s (%s)\n\n' "$title" "${CNT[$sec]}"
  if [[ -n "${TBL[$sec]}" ]]; then
    printf '| ID | 指摘 | 箇所 |\n|---|---|---|\n%s\n' "${TBL[$sec]}"
  fi
  printf '%s' "${BODY[$sec]}"
}

# shellcheck disable=SC2016
printf '<!-- deep-review:v1 -->\n## Deep Review\n\nレビュー対象コミット: `%s`\n\n' "$SHA"
section B "マージ前に対応"
section F "後続対応"
section R "解消済み"
unavail=$(jq -r '[.reviewers | to_entries[] | select(.value == "unavailable") | .key] | join(", ")' "$LEDGER")
if [[ -n "$unavail" ]]; then
  printf '### レビュー範囲\n\n未応答のレビュー観点 (%s) は確認できていません。\n' "$unavail"
fi
