#!/bin/bash
# 言語規約のドキュメント整合を検証する。

set -euo pipefail

echo "Testing language policy consistency..."

FAILED=0
cd "$(dirname "$0")/../.."

ok() { echo "✅ $1"; }
ng() { echo "❌ $1"; FAILED=1; }

# grep の終了コード 2 以上(エラー)は「該当なし」とみなさず失敗させる
match() {
  local rc=0
  "$@" || rc=$?
  if [[ $rc -ge 2 ]]; then
    echo "grep failed (exit $rc): $*" >&2
    exit 2
  fi
  return "$rc"
}

# 取り込み先が無ければ @AGENTS.md は何も読み込まない
if [[ -f AGENTS.md ]]; then
  ok "AGENTS.md exists"
else
  ng "AGENTS.md is missing"
fi

# コードフェンス内ではなく単独行としての取り込みを要求する
if match awk '/^```/ { f = !f; next } !f && /^@AGENTS\.md$/ { found = 1 } END { exit !found }' CLAUDE.md; then
  ok "CLAUDE.md imports @AGENTS.md"
else
  ng "CLAUDE.md does not import @AGENTS.md"
fi

# 英語限定のファイルに日本語が混入していない
if match env LC_ALL=C.UTF-8 grep -rP "[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]" home/dot_codex .github/copilot-instructions.md --include=*.md; then
  ng "Japanese text found in home/dot_codex Markdown or .github/copilot-instructions.md"
else
  ok "No Japanese text in home/dot_codex Markdown or .github/copilot-instructions.md"
fi

if [[ $FAILED -eq 0 ]]; then
  echo "✅ All language policy tests passed"
  exit 0
else
  echo "❌ Some language policy tests failed"
  exit 1
fi
