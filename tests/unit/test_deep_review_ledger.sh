#!/bin/bash
# deep-review ledger.sh のユニットテスト (不変条件とブロック述語)

set -uo pipefail

echo "Testing deep-review ledger.sh..."

FAILED=0
LEDGER="$PWD/home/dot_agents/skills/deep-review/scripts/executable_ledger.sh"
export DEEP_REVIEW_DATA_DIR
DEEP_REVIEW_DATA_DIR=$(mktemp -d)
chmod 755 "$DEEP_REVIEW_DATA_DIR"
trap 'rm -rf "$DEEP_REVIEW_DATA_DIR"' EXIT

L() { bash "$LEDGER" "$@"; }

ok() { echo "✅ $1"; }
ng() { echo "❌ $1"; FAILED=1; }

expect_ok() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else ng "$msg (expected success)"; fi
}
expect_fail() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then ng "$msg (expected failure)"; else ok "$msg"; fi
}
expect_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else ng "$1 (got '$2', want '$3')"; fi
}

# finding JSON を組み立てる: key class confidence verified [extra jq object]
f() {
  jq -nc --arg k "$1" --arg c "$2" --argjson conf "$3" --argjson v "$4" --argjson x "${5:-{\}}" \
    '{key: $k, path: "a.kt", line: 1, reviewer: "b", title: "t", class: $c, confidence: $conf, verified: $v} + $x'
}

# --- 自分の PR + fix モード ---
S=own1
expect_ok "init fix/own" L init $S fix pr o/r 1 true abc
expect_fail "invalid session id rejected" L show "../x"

expect_fail "merge-blocker with verified=false rejected" L add $S "$(f k1 merge-blocker 80 false)"
expect_fail "follow-up with verified=false rejected" L add $S "$(f k1f follow-up 80 false)"
expect_ok "follow-up with verified=true accepted" L add $S "$(f k1g follow-up 80 true)"
expect_fail "external dependency without evidence.version rejected (merge-blocker)" \
  L add $S "$(f k2 merge-blocker 80 true '{"external_dependency":true,"evidence":{"source":"doc"}}')"
expect_fail "external dependency without evidence rejected (follow-up)" \
  L add $S "$(f k3 follow-up 80 true '{"external_dependency":true}')"
expect_ok "external dependency with evidence accepted" \
  L add $S "$(f k4 follow-up 80 true '{"external_dependency":true,"evidence":{"source":"doc","version":"1.2"}}')"
expect_fail "missing confidence rejected for follow-up" L add $S "$(f k5 follow-up null true)"
expect_ok "missing confidence accepted for unverified" L add $S "$(f k6 unverified null false)"
expect_fail "personal rule merge-blocker rejected even when own" \
  L add $S "$(f k7 merge-blocker 90 true '{"rule_source":"personal"}')"
expect_ok "personal rule follow-up accepted when own" \
  L add $S "$(f k8 follow-up 90 true '{"rule_source":"personal"}')"
expect_fail "confidence out of range rejected" L add $S "$(f k9 follow-up 101 true)"

expect_eq "no open blockers yet" "$(L count-open-blockers $S)" 0
ID1=$(L add $S "$(f b1 merge-blocker 90 true)")
ID2=$(L add $S "$(f b2 merge-blocker 90 true)")
ID3=$(L add $S "$(f b3 merge-blocker 90 true)")
UID_=$(L add $S "$(f u1 unverified null false)")
expect_eq "3 open blockers counted" "$(L count-open-blockers $S)" 3
expect_eq "add is idempotent (same id)" "$(L add $S "$(f b1 merge-blocker 90 true)")" "$ID1"
expect_eq "idempotent add does not duplicate" "$(L show $S | jq '[.findings[] | select(.key=="b1")] | length')" 1

expect_fail "fixed requires a commit" L set-status $S "$ID1" fixed
expect_fail "fixed requires a verification" L set-status $S "$ID1" fixed deadbeef
expect_fail "fixed rejects empty verification" L set-status $S "$ID1" fixed deadbeef ""
# shellcheck disable=SC2016
expect_fail "fixed rejects empty verification on stdin" bash -c 'printf "" | bash "$0" set-status "$1" "$2" fixed deadbeef -' "$LEDGER" $S "$ID1"
expect_ok "set-status fixed" L set-status $S "$ID1" fixed deadbeef "tests passed"
expect_eq "fix.commit recorded" "$(L show $S | jq -r --argjson i "$ID1" '.findings[] | select(.id==$i) | .fix.commit')" deadbeef
expect_eq "fixed lowers count" "$(L count-open-blockers $S)" 2
expect_ok "set-status false_positive" L set-status $S "$ID2" false_positive
expect_eq "false_positive lowers count" "$(L count-open-blockers $S)" 1
expect_fail "deferred requires follow-up class" L set-status $S "$ID3" deferred
expect_fail "set-class merge-blocker on an unverified finding rejected" L set-class $S "$UID_" merge-blocker
expect_fail "set-class with unknown class rejected" L set-class $S "$ID3" bogus
expect_ok "set-class follow-up" L set-class $S "$ID3" follow-up
expect_ok "set-status deferred after set-class" L set-status $S "$ID3" deferred
expect_eq "deferred lowers count to 0" "$(L count-open-blockers $S)" 0
expect_fail "status transition only from open" L set-status $S "$ID1" false_positive
expect_ok "set-reviewer" L set-reviewer $S b unavailable
expect_eq "reviewer recorded" "$(L show $S | jq -r '.reviewers.b')" unavailable
expect_ok "set-baseline" L set-baseline $S '{"index_tree":"t","tracked_diff_sha":"d","untracked":[]}'
expect_eq "baseline merged" "$(L show $S | jq -r '.baseline.head_sha + .baseline.index_tree')" abct
expect_fail "second set-baseline rejected" L set-baseline $S '{"index_tree":"t2","tracked_diff_sha":"d2","untracked":[]}'
expect_eq "second set-baseline left snapshot intact" "$(L show $S | jq -r '.baseline.index_tree')" t
SHA40=$(printf 'a%.0s' $(seq 40))
expect_fail "set-head rejects non-40-hex" L set-head $S abc
expect_ok "set-head" L set-head $S "$SHA40"
expect_eq "set-head updates head_sha" "$(L show $S | jq -r '.baseline.head_sha')" "$SHA40"
expect_eq "set-head keeps snapshot" "$(L show $S | jq -r '.baseline.index_tree')" t
expect_eq "ledger file mode 600" "$(stat -c %a "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json")" 600
expect_eq "data dir mode 700" "$(stat -c %a "$DEEP_REVIEW_DATA_DIR")" 700

# --- init は open な merge-blocker を持つ ledger を黙ってリセットしない ---
S=init1
L init $S fix pr o/r 1 true abc >/dev/null
IB=$(L add $S "$(f ib1 merge-blocker 90 true)")
expect_fail "init refused while open merge-blockers exist" L init $S fix pr o/r 1 true abc
expect_eq "refused init kept the finding" "$(L show $S | jq '.findings | length')" 1
expect_ok "init --force overrides" L init $S --force fix pr o/r 1 true abc
IB=$(L add $S "$(f ib1 merge-blocker 90 true)")
L set-status $S "$IB" false_positive >/dev/null
expect_ok "init allowed once blockers are resolved" L init $S fix pr o/r 1 true abc

# --- 入力検証 ---
S=val1
L init $S fix local o/r - true abc >/dev/null
expect_fail "non-integer line rejected" L add $S "$(f v1 follow-up 70 true '{"line":"1; e"}')"
expect_fail "negative line rejected" L add $S "$(f v2 follow-up 70 true '{"line":-1}')"
expect_fail "fractional line rejected" L add $S "$(f v3 follow-up 70 true '{"line":1.5}')"
expect_fail "missing line rejected" L add $S "$(f v4 follow-up 70 true | jq -c 'del(.line)')"
expect_fail "non-integer line_end rejected" L add $S "$(f v5 follow-up 70 true '{"detail":{"line_end":"1e"}}')"
expect_fail "negative line_end rejected" L add $S "$(f v6 follow-up 70 true '{"detail":{"line_end":-3}}')"
expect_ok "integer line_end accepted" L add $S "$(f v7 follow-up 70 true '{"detail":{"line_end":3}}')"
expect_fail "key with newline rejected" L add $S "$(f $'v8\nx' follow-up 70 true)"
expect_fail "key with space rejected" L add $S "$(f 'v 9' follow-up 70 true)"
expect_fail "key with --> rejected" L add $S "$(f 'v-->10' follow-up 70 true)"
expect_fail "key with ) rejected" L add $S "$(f 'v)11' follow-up 70 true)"
expect_fail "key with control char rejected" L add $S "$(f $'v\t12' follow-up 70 true)"
expect_fail "path with newline rejected" L add $S "$(f v13 follow-up 70 true | jq -c '.path = "a\nb"')"
expect_fail "path with space rejected" L add $S "$(f v14 follow-up 70 true | jq -c '.path = "a b"')"
expect_fail "path with ) rejected" L add $S "$(f v15 follow-up 70 true | jq -c '.path = "a)b"')"
expect_fail "path with --> rejected" L add $S "$(f v16 follow-up 70 true | jq -c '.path = "a-->b"')"

# --- stdin 入力 (信頼できないテキストをコマンドラインに埋め込まない) ---
NASTY="it's \$(touch $DEEP_REVIEW_DATA_DIR/pwned) \`id\` \"q\""
SID=$(f st1 follow-up 70 true | jq -c --arg t "$NASTY" '.title = $t' | L add $S -)
expect_eq "add via stdin keeps special chars verbatim" "$(L show $S | jq -r --argjson i "$SID" '.findings[] | select(.id==$i) | .title')" "$NASTY"
expect_eq "stdin add ran no command substitution" "$([[ -e "$DEEP_REVIEW_DATA_DIR/pwned" ]] && echo yes || echo no)" no
printf '%s' "$NASTY" | L set-status $S "$SID" fixed deadbeef - >/dev/null
expect_eq "set-status verification via stdin verbatim" "$(L show $S | jq -r --argjson i "$SID" '.findings[] | select(.id==$i) | .fix.verification')" "$NASTY"

# --- 他者の PR + review モード ---
S=other1
expect_ok "init review/other" L init $S review pr o/r 2 false abc
expect_fail "personal rule on other's PR rejected as follow-up" \
  L add $S "$(f p1 follow-up 90 true '{"rule_source":"personal"}')"
expect_ok "personal rule on other's PR accepted as out-of-scope" \
  L add $S "$(f p2 out-of-scope 90 false '{"rule_source":"personal"}')"
L add $S "$(f rb1 merge-blocker 90 true)" >/dev/null
expect_eq "review mode always counts 0" "$(L count-open-blockers $S)" 0

# --- 並列 add でも ID が重複しない ---
S=par1
L init $S fix local o/r - true abc >/dev/null
for i in 1 2 3 4 5 6; do L add $S "$(f "p$i" follow-up 70 true)" >/dev/null & done
wait
expect_eq "parallel adds keep all findings" "$(L show $S | jq '.findings | length')" 6
expect_eq "parallel adds keep unique ids" "$(L show $S | jq '[.findings[].id] | unique | length')" 6

if [ $FAILED -eq 0 ]; then
  echo "✅ All deep-review ledger tests passed"
else
  echo "❌ Some deep-review ledger tests failed"
  exit 1
fi
