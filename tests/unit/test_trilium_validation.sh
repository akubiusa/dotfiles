#!/bin/bash
# trilium-common.sh の検証関数(trilium_validate_id / trilium_validate_topic /
# trilium_validate_doc_type)のユニットテスト。ネットワークアクセスは行わない。

set -euo pipefail

echo "Testing trilium-common.sh validation functions..."

FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRILIUM_COMMON="$SCRIPT_DIR/home/bin/trilium-common.sh"

# 各検証関数は exit 1 で終了するため、サブシェルで実行して終了コードのみを見る。
expect_pass() {
  local desc="$1"
  shift
  if (
    # shellcheck source=/dev/null
    source "$TRILIUM_COMMON"
    "$@"
  ) >/dev/null 2>&1; then
    echo "✅ $desc"
  else
    echo "❌ $desc: expected success but failed"
    FAILED=1
  fi
}

expect_fail() {
  local desc="$1"
  shift
  if (
    # shellcheck source=/dev/null
    source "$TRILIUM_COMMON"
    "$@"
  ) >/dev/null 2>&1; then
    echo "❌ $desc: expected failure but succeeded"
    FAILED=1
  else
    echo "✅ $desc"
  fi
}

# trilium_validate_id: 4〜32文字の英数字とアンダースコアのみ許可
expect_pass "trilium_validate_id accepts a 4-char id" trilium_validate_id "abcd" "noteId"
expect_pass "trilium_validate_id accepts a 32-char id" trilium_validate_id "a2345678901234567890123456789012" "noteId"
expect_fail "trilium_validate_id rejects a 3-char id" trilium_validate_id "abc" "noteId"
expect_fail "trilium_validate_id rejects a 33-char id" trilium_validate_id "a23456789012345678901234567890123" "noteId"
expect_fail "trilium_validate_id rejects an id with a space" trilium_validate_id "abc d" "noteId"
expect_fail "trilium_validate_id rejects an id with !" trilium_validate_id "abc!" "noteId"

# trilium_validate_topic: 1〜25文字の英数字・ハイフン・アンダースコアのみ許可
expect_pass "trilium_validate_topic accepts a 1-char topic" trilium_validate_topic "a"
expect_pass "trilium_validate_topic accepts a 25-char topic" trilium_validate_topic "a234567890123456789012345"
expect_fail "trilium_validate_topic rejects a 26-char topic" trilium_validate_topic "a2345678901234567890123456"
expect_fail "trilium_validate_topic rejects a topic containing #" trilium_validate_topic "topic#1"
expect_fail "trilium_validate_topic rejects a topic containing a colon" trilium_validate_topic "topic:1"

# trilium_validate_doc_type: spec/plan/investigation のみ許可
expect_pass "trilium_validate_doc_type accepts spec" trilium_validate_doc_type "spec"
expect_pass "trilium_validate_doc_type accepts plan" trilium_validate_doc_type "plan"
expect_pass "trilium_validate_doc_type accepts investigation" trilium_validate_doc_type "investigation"
expect_fail "trilium_validate_doc_type rejects notavalidtype" trilium_validate_doc_type "notavalidtype"

if [ "$FAILED" -eq 0 ]; then
  echo "✅ All trilium validation tests passed"
else
  echo "❌ Some trilium validation tests failed"
  exit 1
fi
