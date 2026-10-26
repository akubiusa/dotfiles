#!/bin/bash
# deep-review render-comment.sh / validate-comment.sh のユニットテスト

# ok/ng の A && B || C は意図的 (ok/ng は常に成功する)
# shellcheck disable=SC2015
set -uo pipefail

echo "Testing deep-review render/validate comment scripts..."

FAILED=0
SCRIPTS="$PWD/home/dot_agents/skills/deep-review/scripts"
LEDGER="$SCRIPTS/executable_ledger.sh"
RENDER="$SCRIPTS/executable_render-comment.sh"
VALIDATE="$SCRIPTS/executable_validate-comment.sh"

export DEEP_REVIEW_DATA_DIR
DEEP_REVIEW_DATA_DIR=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$DEEP_REVIEW_DATA_DIR" "$WORK"' EXIT

ok() { echo "✅ $1"; }
ng() { echo "❌ $1"; FAILED=1; }
expect_ok() { local m="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$m"; else ng "$m (expected success)"; fi; }
expect_fail() { local m="$1"; shift; if "$@" >/dev/null 2>&1; then ng "$m (expected failure)"; else ok "$m"; fi; }
L() { bash "$LEDGER" "$@"; }

# フィクスチャ: 一時 git リポジトリ
REPO="$WORK/repo"
mkdir -p "$REPO/src"
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false
  git config core.hooksPath /dev/null
  {
    echo 'fun a() {'
    echo '  val x = p || q'
    echo '  val md = "```kotlin"'
    echo '}'
    echo 'fun b() { return 1 }'
  } > src/a.kt
  printf 'x1\ny2\nlast-no-newline' > src/nonl.kt
  printf 'a1\n\n\nb4\n' > src/blank.kt
  printf '# doc\n### heading\nafter\n' > src/h.kt
  git add -A
  git commit -q -m init
) || { echo "❌ fixture setup failed"; exit 1; }
SHA=$(git -C "$REPO" rev-parse HEAD)

f() {
  jq -nc --arg k "$1" --arg c "$2" --arg t "$3" --argjson line "$4" --argjson end "$5" \
    '{key: $k, path: "src/a.kt", line: $line, reviewer: "b", title: $t, class: $c, confidence: 80, verified: true,
      detail: {condition: "when p is `a || b` #12", impact: "impact | with pipe", fix_plan: "fix", line_end: $end}}'
}

# --- 新規本文の生成と検証 ---
S=c1
L init $S review pr o/r 5 true "$SHA" >/dev/null
L add $S "$(f k1 merge-blocker 'Title with | pipe and #12' 2 3)" >/dev/null
L add $S "$(f k2 follow-up 'Second issue' 5 5)" >/dev/null
L add $S "$(f k3 unverified 'Unverified thing' 1 1 | jq -c '.confidence = null | .verified = false')" >/dev/null
L add $S "$(f k4 out-of-scope 'Out of scope thing' 1 1)" >/dev/null
L set-reviewer $S a unavailable >/dev/null

BODY="$WORK/body.md"
bash "$RENDER" $S "$REPO" > "$BODY" 2>"$WORK/err" || { ng "render failed: $(cat "$WORK/err")"; }
expect_ok "render output validates (with ||, |, #12, backtick fence)" bash "$VALIDATE" "$BODY" $S "$REPO"

# フェンス外に #数字 が無いこと (フェンス内のコード引用は対象外)
if awk '/^```/ { f = !f; next } !f && /#[0-9]/ { bad = 1 } END { exit bad }' "$BODY"; then
  ok "no #<number> outside code fences"
else
  ng "body contains #<number> outside code fences"
fi
grep -q 'Unverified thing\|Out of scope thing' "$BODY" && ng "unverified/out-of-scope leaked into body" || ok "unverified/out-of-scope not in body"
grep -q 'Score\|confidence' "$BODY" && ng "score/confidence leaked into body" || ok "no score/confidence in body"
grep -q "blob/$SHA/src/a.kt#L2-L3" "$BODY" && ok "permalink uses full head SHA" || ng "permalink missing"
grep -q '^### マージ前に対応 (1)' "$BODY" && grep -q '^### 後続対応 (1)' "$BODY" && ok "sections and counts" || ng "sections/counts wrong"
grep -q 'a || b\|p || q' "$BODY" && ok "code with || kept in quote" || ng "quote lost"

# --- 検証の失敗ケース ---
sed 's/val x = p || q/val x = p \&\& q/' "$BODY" > "$WORK/tampered.md"
expect_fail "tampered quote fails validation" bash "$VALIDATE" "$WORK/tampered.md" $S "$REPO"
sed "s|blob/$SHA|blob/${SHA:0:7}|" "$BODY" > "$WORK/short.md"
expect_fail "short SHA fails validation" bash "$VALIDATE" "$WORK/short.md" $S "$REPO"
# 詳細ブロック 1 件 (k2) を消して件数不一致にする (表の行は残る)
awk '/^<!-- finding:k2:/ { skip = 1 } !skip { print } /^<!-- \/finding -->/ { skip = 0 }' "$BODY" > "$WORK/count.md"
expect_fail "count mismatch fails validation" bash "$VALIDATE" "$WORK/count.md" $S "$REPO"
sed 's/^\(| 指摘[0-9]* | [^|]*|.*\)$/\1 extra |/' "$BODY" > "$WORK/cols.md"
expect_fail "inconsistent table columns fail validation" bash "$VALIDATE" "$WORK/cols.md" $S "$REPO"
sed 's/^- 修正方針: fix$/- 修正方針: see #34/' "$BODY" > "$WORK/hash.md"
expect_fail "raw #<number> reference fails validation" bash "$VALIDATE" "$WORK/hash.md" $S "$REPO"

# --- 更新フロー ---
# 投稿済み本文 (BODY) から、k1 を解消し、k5 を新規追加する
L set-status $S 1 fixed abc123 verified >/dev/null
L add $S "$(f k5 follow-up 'Third issue' 4 4)" >/dev/null
UPD="$WORK/updated.md"
bash "$RENDER" --update $S "$REPO" "$BODY" > "$UPD" 2>"$WORK/err" || ng "render --update failed: $(cat "$WORK/err")"
expect_ok "updated body validates" bash "$VALIDATE" "$UPD" $S "$REPO"
grep -q '^### 解消済み (1)' "$UPD" && ok "resolved finding moved to 解消済み" || ng "解消済み section missing"
# 既存の継続指摘 (k2) ブロックが無変更で保持される
old_k2=$(awk '/^<!-- finding:k2:/ { p = 1 } p { print } /^<!-- \/finding -->/ { p = 0 }' "$BODY")
new_k2=$(awk '/^<!-- finding:k2:/ { p = 1 } p { print } /^<!-- \/finding -->/ { p = 0 }' "$UPD")
[[ -n "$old_k2" && "$old_k2" == "$new_k2" ]] && ok "continuing finding block preserved verbatim" || ng "continuing block changed"
grep -q '^<!-- finding:k5:' "$UPD" && ok "new finding appended" || ng "new finding missing"
# 解消済みブロックは既存のコード引用行を保持する
awk '/^### 解消済み/ { p = 1 } p' "$UPD" | grep -q 'p || q' && ok "resolved block keeps quote" || ng "resolved block lost quote"

# --- 引用範囲の正規化 (末尾改行なしのファイル / 空行で終わる範囲) ---
S=c3
L init $S review pr o/r 5 true "$SHA" >/dev/null
L add $S "$(f n1 follow-up 'No trailing newline' 2 3 | jq -c '.path = "src/nonl.kt"')" >/dev/null
L add $S "$(f n2 follow-up 'Ends on blank lines' 1 3 | jq -c '.path = "src/blank.kt"')" >/dev/null
bash "$RENDER" $S "$REPO" > "$WORK/norm.md" 2>"$WORK/err" || ng "render failed: $(cat "$WORK/err")"
expect_ok "range on file without trailing newline validates" bash "$VALIDATE" "$WORK/norm.md" $S "$REPO"

# --- 引用に ### 行を含む解消済みブロックが --update で失われない ---
S=c4
L init $S review pr o/r 5 true "$SHA" >/dev/null
L add $S "$(f h1 follow-up 'Heading in quote' 1 3 | jq -c '.path = "src/h.kt"')" >/dev/null
L add $S "$(f h2 follow-up 'Second resolved' 1 3 | jq -c '.path = "src/h.kt"')" >/dev/null
bash "$RENDER" $S "$REPO" > "$WORK/h0.md" 2>"$WORK/err" || ng "render failed: $(cat "$WORK/err")"
L set-status $S 1 fixed abc123 verified >/dev/null
L set-status $S 2 fixed abc123 verified >/dev/null
L add $S "$(f h3 follow-up 'Still open' 5 5)" >/dev/null
bash "$RENDER" --update $S "$REPO" "$WORK/h0.md" > "$WORK/h1.md" 2>"$WORK/err" || ng "render --update failed: $(cat "$WORK/err")"
grep -q '^### 解消済み (2)' "$WORK/h1.md" && ok "both resolved blocks survive a ### line in a quote" || ng "resolved block dropped"
grep -q '^<!-- finding:h2:' "$WORK/h1.md" && ok "second resolved block kept" || ng "second resolved block missing"
expect_ok "body with ### in quote validates" bash "$VALIDATE" "$WORK/h1.md" $S "$REPO"

# --- 不正な行範囲 / ledger の拒否 ---
S=c5
L init $S review pr o/r 5 true "$SHA" >/dev/null
L add $S "$(f e1 follow-up 'Bad range' 1 1)" >/dev/null
jq '.findings[0].line = "1;e"' "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json" > "$WORK/t.json" \
  && mv "$WORK/t.json" "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json"
expect_fail "render rejects non-integer line" bash "$RENDER" $S "$REPO"
jq '.findings[0].line = 3 | .findings[0].detail.line_end = 1' "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json" > "$WORK/t.json" \
  && mv "$WORK/t.json" "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json"
expect_fail "render rejects line_end < line" bash "$RENDER" $S "$REPO"
jq '.findings[0].line = 1 | .findings[0].detail.line_end = "2;e"' "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json" > "$WORK/t.json" \
  && mv "$WORK/t.json" "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json"
expect_fail "render rejects non-integer line_end" bash "$RENDER" $S "$REPO"
jq 'del(.findings)' "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json" > "$WORK/t.json" \
  && mv "$WORK/t.json" "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json"
expect_fail "render rejects ledger without findings array" bash "$RENDER" $S "$REPO"
jq '.baseline.head_sha = "abc"' "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json" > "$WORK/t.json" \
  && mv "$WORK/t.json" "$DEEP_REVIEW_DATA_DIR/deep-review-ledger-$S.json"
expect_fail "validate rejects non-40-hex head SHA" bash "$VALIDATE" "$BODY" $S "$REPO"

printf 'no marker here\n' > "$WORK/nomarker.md"
expect_fail "existing body without marker is not updatable" bash "$RENDER" --update $S "$REPO" "$WORK/nomarker.md"

if [ $FAILED -eq 0 ]; then
  echo "✅ All deep-review comment tests passed"
else
  echo "❌ Some deep-review comment tests failed"
  exit 1
fi
