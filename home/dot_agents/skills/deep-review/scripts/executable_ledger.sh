#!/usr/bin/env bash
# deep-review の ledger (指摘の状態管理) を操作する。書き込みはこのスクリプトのみが行う。
# 使い方は case 文の各サブコマンドを参照。不変条件違反は非 0 終了する。
# 信頼できないテキスト (指摘の本文・検証内容) をシェルのコマンドラインに埋め込まないよう、
# 次の 2 か所は引数に `-` を渡すと stdin から読む:
#   add <session> -                                  (stdin = finding JSON)
#   set-status <session> <id> fixed <commit> -       (stdin = verification 文)

# jq フィルタは意図的にシングルクォートで渡す
# shellcheck disable=SC2016
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

DATA_DIR="${DEEP_REVIEW_DATA_DIR:-$HOME/.claude/data}"

[[ $# -ge 2 ]] || die "usage: ledger.sh <init|add|set-status|set-class|set-reviewer|set-baseline|set-head|count-open-blockers|show> <session> ..."
CMD="$1"
SESSION="$2"
shift 2

# SESSION_ID をパスに使う前に検証する
[[ "$SESSION" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid session id"
FILE="$DATA_DIR/deep-review-ledger-${SESSION}.json"

# 指摘 1 件分の不変条件。違反時は jq の error で非 0 終了する。
CHECK='
def isuint: type == "number" and . >= 0 and floor == . and (tostring | test("^[0-9]+$"));
def safeid: type == "string" and length > 0 and (test("[\u0000-\u0020\u007f)]") | not) and (contains("-->") | not);
def chk($own):
  (if (.class | IN("merge-blocker","follow-up","unverified","out-of-scope") | not) then error("invalid class") else . end)
  | (if .confidence == null and .class != "unverified" then error("confidence is required unless class=unverified") else . end)
  | (if .confidence != null and ((.confidence | type) != "number" or .confidence < 0 or .confidence > 100 or (.confidence | floor) != .confidence) then error("confidence must be an integer 0-100") else . end)
  | (if (.class | IN("merge-blocker","follow-up")) and .verified != true then error("merge-blocker and follow-up require verified=true") else . end)
  | (if .external_dependency == true and (.class | IN("merge-blocker","follow-up")) and ((.evidence.source // "") == "" or (.evidence.version // "") == "") then error("external dependency requires evidence.source and evidence.version") else . end)
  | (if .rule_source == "personal" and ($own | not) and .class != "out-of-scope" then error("personal rule on a non-own target must be out-of-scope") else . end)
  | (if .rule_source == "personal" and .class == "merge-blocker" then error("personal rule cannot be merge-blocker") else . end);
'

# flock + 一時ファイル + mv で原子的に更新する。引数は jq への追加引数 (最後がフィルタ)
mutate() {
  [[ -f "$FILE" ]] || die "ledger not found: $FILE"
  (
    flock 9
    tmp=$(mktemp "$FILE.XXXXXX")
    if jq "$@" "$FILE" > "$tmp"; then
      chmod 600 "$tmp"
      mv "$tmp" "$FILE"
    else
      rm -f "$tmp"
      exit 1
    fi
  ) 9>"$FILE.lock"
}

case "$CMD" in
  init)
    FORCE=0
    if [[ "${1:-}" == "--force" ]]; then FORCE=1; shift; fi
    [[ $# -eq 6 ]] || die "usage: init <session> [--force] <mode> <kind> <repo> <pr|-> <own> <head_sha>"
    [[ "$1" =~ ^(review|fix)$ ]] || die "invalid mode"
    [[ "$2" =~ ^(pr|local)$ ]] || die "invalid kind"
    [[ "$5" =~ ^(true|false)$ ]] || die "own must be true or false"
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    if [[ $FORCE -eq 0 && -f "$FILE" ]]; then
      n=$(jq '.mode as $m | [.findings[] | select($m == "fix" and .class == "merge-blocker" and .status == "open")] | length' "$FILE" 2>/dev/null || echo 0)
      [[ "$n" -eq 0 ]] || die "ledger for this session still has $n open merge-blocker findings; resolve them or re-run with --force"
    fi
    pr=null
    [[ "$4" == "-" ]] || pr="$4"
    (
      flock 9
      jq -n --arg s "$SESSION" --arg mode "$1" --arg kind "$2" --arg repo "$3" \
        --argjson pr "$pr" --argjson own "$5" --arg sha "$6" '
        {schema_version: 1, session_id: $s, mode: $mode,
         target: {kind: $kind, repo: $repo, pr: $pr, own: $own},
         baseline: {head_sha: $sha}, reviewers: {}, findings: [], updated_at: (now | floor)}' > "$FILE.new"
      chmod 600 "$FILE.new"
      mv "$FILE.new" "$FILE"
    ) 9>"$FILE.lock"
    ;;
  add)
    [[ $# -eq 1 ]] || die "usage: add <session> <json|->"
    if [[ "$1" == "-" ]]; then FJSON=$(cat); else FJSON="$1"; fi
    mutate --argjson f "$FJSON" "$CHECK"'
      .target.own as $own
      | ($f | (if (.key | safeid) then . else error("key must not contain control characters, spaces, `)` or `-->`") end)
            | (if (.path | safeid) then . else error("path must not contain control characters, spaces, `)` or `-->`") end)
            | (if (.line | isuint) then . else error("line must be a non-negative integer") end)
            | (if (.detail.line_end // 0 | isuint) then . else error("detail.line_end must be a non-negative integer") end)) as $_
      | ({confidence: null, verified: false, external_dependency: false, rule_source: "none",
          evidence: null, depends_on: [], detail: {}, line: null} + $f) as $n
      | ($n | chk($own)) as $_
      | if any(.findings[]; .key == $n.key and .path == $n.path) then .
        else .findings += [$n + {id: ((.findings | map(.id) | max // 0) + 1), status: "open", fix: {commit: null, verification: null}}]
        end
      | .updated_at = (now | floor)'
    jq -r --argjson f "$FJSON" '.findings[] | select(.key == $f.key and .path == $f.path) | .id' "$FILE"
    ;;
  set-status)
    [[ $# -ge 2 && $# -le 4 ]] || die "usage: set-status <session> <id> <status> [<fix_commit> [<fix_verification|->]]"
    [[ "$1" =~ ^[0-9]+$ ]] || die "invalid id"
    [[ "$2" =~ ^(fixed|false_positive|deferred)$ ]] || die "invalid status"
    VERIF="${4:-}"
    if [[ "$VERIF" == "-" ]]; then VERIF=$(cat); fi
    if [[ "$2" == "fixed" ]]; then
      [[ -n "${3:-}" && -n "$VERIF" ]] || die "fixed requires non-empty fix_commit and fix_verification"
    fi
    mutate --argjson id "$1" --arg st "$2" --arg c "${3:-}" --arg v "$VERIF" '
      (.findings | map(select(.id == $id)) | first) as $f
      | if $f == null then error("finding not found")
        elif $f.status != "open" then error("status transition only allowed from open")
        elif $st == "deferred" and $f.class != "follow-up" then error("deferred requires class=follow-up (run set-class first)")
        else .findings |= map(if .id == $id then
            (.status = $st)
            | if $st == "fixed" then .fix = {commit: (if $c == "" then null else $c end), verification: (if $v == "" then null else $v end)} else . end
          else . end)
        end
      | .updated_at = (now | floor)'
    ;;
  set-class)
    [[ $# -eq 2 && "$1" =~ ^[0-9]+$ ]] || die "usage: set-class <session> <id> <class>"
    mutate --argjson id "$1" --arg c "$2" "$CHECK"'
      .target.own as $own
      | (.findings | map(select(.id == $id)) | first) as $f
      | if $f == null then error("finding not found") else . end
      | ($f | .class = $c | chk($own)) as $_
      | .findings |= map(if .id == $id then .class = $c else . end)
      | .updated_at = (now | floor)'
    ;;
  set-reviewer)
    [[ $# -eq 2 && "$2" =~ ^(responded|unavailable)$ ]] || die "usage: set-reviewer <session> <slug> <responded|unavailable>"
    mutate --arg s "$1" --arg v "$2" '.reviewers[$s] = $v | .updated_at = (now | floor)'
    ;;
  set-baseline)
    [[ $# -eq 1 ]] || die "usage: set-baseline <session> <json>"
    mutate --argjson b "$1" 'if .baseline.index_tree != null then error("baseline snapshot already recorded") else . end
      | .baseline += ($b | del(.head_sha)) | .updated_at = (now | floor)'
    ;;
  set-head)
    [[ $# -eq 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || die "usage: set-head <session> <40-hex-sha>"
    mutate --arg sha "$1" '.baseline.head_sha = $sha | .updated_at = (now | floor)'
    ;;
  count-open-blockers)
    [[ -f "$FILE" ]] || die "ledger not found: $FILE"
    jq '.mode as $m | [.findings[] | select($m == "fix" and .class == "merge-blocker" and .status == "open")] | length' "$FILE"
    ;;
  show)
    [[ -f "$FILE" ]] || die "ledger not found: $FILE"
    cat "$FILE"
    ;;
  *) die "unknown subcommand: $CMD" ;;
esac
