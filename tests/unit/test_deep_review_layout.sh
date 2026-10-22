#!/bin/bash
# deep-review スキルが ZIP でインポートできる自己完結構成であることを検証する。
# - Claude 側スキルディレクトリが scripts/ references/ reviewers/ を内包すること
# - SKILL.md がスキル外 (~/.agents など) のスクリプトを参照しないこと
# - Codex 側 (dot_agents) のスクリプト・references と内容が一致すること

set -uo pipefail

echo "Testing deep-review skill layout (ZIP importable)..."

FAILED=0
CLAUDE_DIR="$PWD/home/dot_claude/skills/deep-review"
AGENTS_DIR="$PWD/home/dot_agents/skills/deep-review"

ok() { echo "✅ $1"; }
ng() { echo "❌ $1"; FAILED=1; }

# --- 必要なファイルが executable_ なしの名前で存在する (ZIP でも同名で展開される) ---
for f in scripts/ledger.sh scripts/render-comment.sh scripts/validate-comment.sh scripts/measure-usage.sh references/regression-cases.md; do
  if [[ -f "$CLAUDE_DIR/$f" ]]; then ok "$f exists in Claude skill directory"; else ng "$f missing in Claude skill directory"; fi
done

if compgen -G "$CLAUDE_DIR/reviewers/*.md" >/dev/null; then ok "reviewers/*.md exist"; else ng "reviewers/*.md missing"; fi

if find "$CLAUDE_DIR" -name 'executable_*' | grep -q .; then
  ng "executable_ prefixed files must not exist in the Claude skill directory (names would differ in a ZIP)"
else
  ok "no executable_ prefixed files in the Claude skill directory"
fi

# --- SKILL.md がスキル外のスクリプト・参照ファイルを指していない ---
# shellcheck disable=SC2088 # チルダはパスの文字列検索パターンであり展開しない
if grep -nE '~/\.agents/skills/deep-review|~/\.claude/skills/deep-review' "$CLAUDE_DIR/SKILL.md"; then
  ng "SKILL.md references deep-review files outside the skill directory"
else
  ok "SKILL.md has no external deep-review path references"
fi

if grep -q 'SKILL_DIR' "$CLAUDE_DIR/SKILL.md"; then ok "SKILL.md defines SKILL_DIR"; else ng "SKILL.md must define SKILL_DIR"; fi

# SKILL.md が $SKILL_DIR/<path> で参照するファイルがすべて存在する
# shellcheck disable=SC2016 # $SKILL_DIR はパターン中のリテラル文字列であり展開しない
while IFS= read -r ref; do
  if [[ -e "$CLAUDE_DIR/$ref" ]]; then
    ok "SKILL.md reference resolves: $ref"
  else
    ng "SKILL.md reference does not resolve: $ref"
  fi
done < <(grep -oE '\$SKILL_DIR/[A-Za-z0-9_./-]+' "$CLAUDE_DIR/SKILL.md" | sed 's|^\$SKILL_DIR/||; s|/\*\.md$||; s|\.$||' | sort -u)

# --- Codex 側との内容一致 (ドリフト防止) ---
for name in ledger render-comment validate-comment measure-usage; do
  if cmp -s "$CLAUDE_DIR/scripts/$name.sh" "$AGENTS_DIR/scripts/executable_$name.sh"; then
    ok "scripts/$name.sh is identical between Claude and Codex"
  else
    ng "scripts/$name.sh differs between Claude and Codex (update both copies)"
  fi
done

if cmp -s "$CLAUDE_DIR/references/regression-cases.md" "$AGENTS_DIR/references/regression-cases.md"; then
  ok "references/regression-cases.md is identical between Claude and Codex"
else
  ng "references/regression-cases.md differs between Claude and Codex (update both copies)"
fi

if [[ $FAILED -eq 0 ]]; then
  echo "✅ All deep-review layout tests passed"
  exit 0
else
  echo "❌ Some deep-review layout tests failed"
  exit 1
fi
