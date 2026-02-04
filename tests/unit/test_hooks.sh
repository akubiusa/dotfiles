#!/bin/bash
# Claude Code フックのユニットテスト

set -euo pipefail

echo "Testing Claude Code hooks..."

FAILED=0

# テスト対象のフックスクリプト
HOOKS=(
  "home/dot_claude/hooks/executable_code-review-immediate-fix.sh"
  "home/dot_claude/hooks/executable_require-code-review-fixes.sh"
  "home/dot_claude/hooks/executable_require-review-thread-fixes.sh"
)

# 各フックの構文チェック
for hook in "${HOOKS[@]}"; do
  if [ ! -f "$hook" ]; then
    echo "⚠️  Hook not found: $hook"
    continue
  fi

  echo "Testing hook: $hook"

  # bash 構文チェック
  if ! bash -n "$hook"; then
    echo "❌ Syntax error in hook: $hook"
    FAILED=1
  else
    echo "✅ Syntax OK: $hook"
  fi
done

if [ $FAILED -eq 0 ]; then
  echo "✅ All hook tests passed"
else
  echo "❌ Some hook tests failed"
  exit 1
fi
