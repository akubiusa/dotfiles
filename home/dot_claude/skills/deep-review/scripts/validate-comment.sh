#!/usr/bin/env bash
# render-comment.sh が生成した本文を ledger と git の実体に照らして検証する。
#   validate-comment.sh <body-file> <session> <repo-dir>
# 失敗理由を stderr に出して非 0 終了する。

set -euo pipefail

FAILED=0
fail() { echo "INVALID: $*" >&2; FAILED=1; }

[[ $# -eq 3 ]] || { echo "ERROR: usage: validate-comment.sh <body-file> <session> <repo-dir>" >&2; exit 1; }
BODY="$1"; SESSION="$2"; REPO_DIR="$3"
[[ -f "$BODY" ]] || { echo "ERROR: body file not found" >&2; exit 1; }
[[ "$SESSION" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: invalid session id" >&2; exit 1; }
LEDGER="${DEEP_REVIEW_DATA_DIR:-$HOME/.claude/data}/deep-review-ledger-${SESSION}.json"
[[ -f "$LEDGER" ]] || { echo "ERROR: ledger not found: $LEDGER" >&2; exit 1; }
SHA=$(jq -r '.baseline.head_sha' "$LEDGER")
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: ledger head_sha must be a full 40-char SHA: $SHA" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

grep -qxF '<!-- deep-review:v1 -->' "$BODY" || fail "missing deep-review marker"

# フェンス外の行だけを見て、表・ブロック・リンク・引用を記録として書き出す。
# フェンスの開閉はバッククォート連続の長さで判定する (長いフェンス内の短い ``` を無視するため)。
awk -v d="$TMP" '
  function bt(s) { return match(s, /^`+/) ? RLENGTH : 0 }
  {
    line = $0
    if (fence) {
      if (bt(line) >= flen && bt(line) == length(line)) { fence = 0; if (inq) { close(qf); inq = 0 } }
      else if (inq) print line >> qf
      next
    }
    if (bt(line) >= 3) {
      fence = 1; flen = bt(line)
      if (cur != "" && !hasq) { n++; qf = d "/q." n; printf "" > qf; print "QUOTE", n, cur > (d "/rec"); inq = 1; hasq = 1 }
      next
    }
    if (line ~ /^### /) { sec = (line ~ /^### マージ前に対応/) ? "B" : (line ~ /^### 後続対応/) ? "F" : (line ~ /^### 解消済み/) ? "R" : "X" }
    if (line ~ /^<!-- finding:/) { cur = line; sub(/^<!-- finding:/, "", cur); sub(/ -->$/, "", cur); hasq = 0 }
    if (line ~ /^<!-- \/finding -->/) { cur = "" }
    if (line ~ /^#### 指摘[0-9]+:/) { id = line; sub(/^#### 指摘/, "", id); sub(/:.*/, "", id); print "BLK", sec, id, cur > (d "/rec") }
    if (line ~ /^\| 指摘[0-9]+ \|/) { id = line; sub(/^\| 指摘/, "", id); sub(/ .*/, "", id); print "ROW", sec, id > (d "/rec") }
    if (line ~ /^\|/) { t = line; gsub(/\\\|/, "", t); if (gsub(/\|/, "", t) != 4) print "BADCOLS", line > (d "/rec") }
    if (line ~ /#[0-9]/) print "HASH", line > (d "/rec")
    if (cur != "" && match(line, /https:\/\/github\.com\/[^ )]+/)) print "LINK", cur, substr(line, RSTART, RLENGTH) > (d "/rec")
  }
' "$BODY"
touch "$TMP/rec"

grep -q '^BADCOLS' "$TMP/rec" && fail "table column count is inconsistent"
grep -q '^HASH' "$TMP/rec" && fail "unintended #<number> reference outside code"

# 一覧と詳細の ID / 件数の一致 (節ごと)
for s in B F R; do
  rows=$(awk -v s="$s" '$1 == "ROW" && $2 == s { print $3 }' "$TMP/rec" | sort -n | tr '\n' ' ')
  blks=$(awk -v s="$s" '$1 == "BLK" && $2 == s { print $3 }' "$TMP/rec" | sort -n | tr '\n' ' ')
    if [[ "$s" != "R" && "$rows" != "$blks" ]]; then fail "section $s: table IDs ($rows) != detail IDs ($blks)"; fi
done
dups=$(awk '$1 == "BLK" { print $3 }' "$TMP/rec" | sort | uniq -d | tr '\n' ' ')
[[ -z "$dups" ]] || fail "duplicate IDs: $dups"

# ledger の継続中指摘 (open/deferred の merge-blocker/follow-up) と詳細ブロックの集合・区分が一致すること
want=$(jq -r '.findings[] | select((.status == "open" or .status == "deferred") and (.class == "merge-blocker" or .class == "follow-up")) | (if .class == "merge-blocker" then "B " else "F " end) + .key + ":" + .path' "$LEDGER" | sort)
have=$(awk '$1 == "BLK" && $2 != "R" { print $2 " " $4 }' "$TMP/rec" | sort)
[[ "$want" == "$have" ]] || fail "detail blocks do not match ledger (want: $(echo "$want" | tr '\n' ',') have: $(echo "$have" | tr '\n' ',')"

while read -r _ sec _ kp; do
  path=${kp#*:}
  link=$(awk -v k="$kp" '$1 == "LINK" && $2 == k { print $3 }' "$TMP/rec" | head -n 1)
  qn=$(awk -v k="$kp" '$1 == "QUOTE" && $3 == k { print $2 }' "$TMP/rec" | head -n 1)
  [[ -n "$link" && -n "$qn" ]] || { fail "$kp: missing link or code quote"; continue; }
  # 解消済み節は過去 SHA の引用を保持するため構造のみ確認する
  [[ "$sec" != "R" ]] || continue
  if [[ ! "$link" =~ ^https://github\.com/[^/]+/[^/]+/blob/([0-9a-f]{40})/(.+)#L([0-9]+)-L([0-9]+)$ ]]; then
    fail "$kp: link must use a full 40-char SHA and #L<a>-L<b>: $link"; continue
  fi
  lsha=${BASH_REMATCH[1]}; lpath=${BASH_REMATCH[2]}; a=${BASH_REMATCH[3]}; b=${BASH_REMATCH[4]}
  [[ "$lsha" == "$SHA" ]] || fail "$kp: link SHA differs from head SHA"
  [[ "$lpath" == "$path" ]] || fail "$kp: link path differs from finding path"
  # render-comment.sh と同じく末尾改行を除去した文字列で比較する
  want_quote=$(git -C "$REPO_DIR" show "$SHA:$path" 2>/dev/null | sed -n "${a},${b}p" || true)
  have_quote=$(cat "$TMP/q.$qn")
  if [[ "$want_quote" != "$have_quote" ]]; then
    fail "$kp: code quote does not match $SHA:$path lines $a-$b"
  fi
done < <(grep '^BLK' "$TMP/rec")

exit $FAILED
