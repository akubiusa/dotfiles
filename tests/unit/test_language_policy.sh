#!/bin/bash
# 言語規約のドキュメント整合を検証する。
# - グローバル指示・Copilot 指示・CLAUDE.md・AGENTS.md・README.md に「未指定時の既定言語」の記述が残っていないこと
# - home/dot_codex 配下の Markdown に日本語が含まれないこと
# - ルート AGENTS.md が存在し、言語見出しを持ち、CLAUDE.md から単独行で取り込まれ、旧方針の記述が残っていないこと

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

# --- (1) 未指定時の既定言語の記述がない (このテスト自身は tests/ 配下で対象外) ---
FALLBACK_PATTERN="otherwise (Japanese|English)|default English|未指定なら日本語|Default to (Japanese|English)|unless the (project|repository) specifies|指定がなければ(日本語|英語)|When no language is specified"
if match grep -rniE "$FALLBACK_PATTERN" home/dot_claude home/dot_codex home/dot_agents .github/copilot-instructions.md CLAUDE.md AGENTS.md README.md; then
  ng "Default-language fallback wording found in global instructions"
else
  ok "No default-language fallback wording in global instructions"
fi

# --- (2) home/dot_codex 配下の Markdown に日本語がない ---
if match env LC_ALL=C.UTF-8 grep -rP "[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]" home/dot_codex --include=*.md; then
  ng "Japanese text found in home/dot_codex Markdown"
else
  ok "No Japanese text in home/dot_codex Markdown"
fi

# --- (3) ルート AGENTS.md と関連ドキュメント ---
if [[ -f AGENTS.md ]] && [[ "$(wc -l < AGENTS.md)" -lt 100 ]]; then
  ok "AGENTS.md exists and is under 100 lines"
else
  ng "AGENTS.md is missing or has 100 lines or more"
fi

if match grep -q '^## 日本語で記載するもの' AGENTS.md && match grep -q '^## 英語で記載するもの' AGENTS.md; then
  ok "AGENTS.md has the Japanese and English language headings"
else
  ng "AGENTS.md is missing a language heading"
fi

# コードフェンス内ではなく単独行としての取り込みを要求する
if match grep -qE '^@AGENTS\.md$' CLAUDE.md; then
  ok "CLAUDE.md imports @AGENTS.md"
else
  ng "CLAUDE.md does not import @AGENTS.md"
fi

if match grep -nE 'AGENTS\.md.*置かない|2 点に集約' CLAUDE.md README.md .github/copilot-instructions.md; then
  ng "Obsolete 'no AGENTS.md' wording remains"
else
  ok "No obsolete 'no AGENTS.md' wording"
fi

if [[ $FAILED -eq 0 ]]; then
  echo "✅ All language policy tests passed"
  exit 0
else
  echo "❌ Some language policy tests failed"
  exit 1
fi
