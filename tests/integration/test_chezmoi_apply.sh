#!/bin/bash
# chezmoi apply の統合テスト

set -euo pipefail

echo "Testing chezmoi apply..."

# テスト用の HOME ディレクトリを作成
TEST_HOME=$(mktemp -d)
export HOME=$TEST_HOME
export XDG_CONFIG_HOME="$TEST_HOME/.config"

# テスト終了時にクリーンアップ
cleanup() {
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# chezmoi バイナリの場所を確認
CHEZMOI_BIN="./bin/chezmoi"
if [ ! -x "$CHEZMOI_BIN" ]; then
  # リポジトリに含まれていない場合は chezmoi をインストール
  echo "chezmoi not found in ./bin/, installing..."
  curl -sfL https://git.io/chezmoi | sh -s -- -b "$TEST_HOME/bin"
  CHEZMOI_BIN="$TEST_HOME/bin/chezmoi"
fi

# chezmoi を初期化
# .chezmoiroot ファイルが存在するため、リポジトリルート全体をソースとして指定
SOURCE_DIR="$(pwd)"
"$CHEZMOI_BIN" init --source="$SOURCE_DIR"

# 旧 managed file と意図的な unmanaged file を用意し、削除追従を検証する。
STALE_TARGETS=(
  "$HOME/.bashrc.d/91-tmux-ipc.sh"
  "$HOME/.claude/RTK.md"
  "$HOME/.claude/commands/issue-pr.md"
  "$HOME/.codex/hooks/tmux-ipc-check.sh"
  "$HOME/bin/tmux-ipc-send.sh"
)
for target in "${STALE_TARGETS[@]}"; do
  mkdir -p "$(dirname "$target")"
  printf 'stale\n' > "$target"
done
LOCAL_RUNTIME_FILE="$HOME/.claude/local-runtime-state.keep"
printf 'keep\n' > "$LOCAL_RUNTIME_FILE"

# dotfiles 管理から外した chezmoi updater unit は既存 target を保持する。
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR/timers.target.wants"
printf 'local-service\n' > "$SYSTEMD_USER_DIR/chezmoi-update.service"
printf 'local-timer\n' > "$SYSTEMD_USER_DIR/chezmoi-update.timer"
ln -s ../chezmoi-update.timer "$SYSTEMD_USER_DIR/timers.target.wants/chezmoi-update.timer"

# chezmoi apply を実行 (dry-run)
if ! "$CHEZMOI_BIN" apply --dry-run --source="$SOURCE_DIR"; then
  echo "❌ chezmoi apply dry-run failed"
  exit 1
fi

echo "✅ chezmoi apply dry-run passed"

# 実際に apply
if ! "$CHEZMOI_BIN" apply --source="$SOURCE_DIR"; then
  echo "❌ chezmoi apply failed"
  exit 1
fi

echo "✅ chezmoi apply passed"

for target in "${STALE_TARGETS[@]}"; do
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "❌ stale managed target was not removed: $target"
    exit 1
  fi
done
if [ ! -f "$LOCAL_RUNTIME_FILE" ]; then
  echo "❌ intentionally unmanaged runtime file was removed"
  exit 1
fi
echo "✅ stale managed targets removed while local runtime file was preserved"

# 生成されたファイルの検証
if [ ! -f "$HOME/.bashrc" ]; then
  echo "❌ .bashrc not generated"
  exit 1
fi

if [ ! -d "$HOME/.bashrc.d" ]; then
  echo "❌ .bashrc.d directory not generated"
  exit 1
fi

echo "✅ Basic files generated successfully"

if [ ! -f "$HOME/.profile" ]; then
  echo "❌ .profile not generated"
  exit 1
fi

if ! grep -Fq 'mise activate bash --shims' "$HOME/.profile"; then
  echo "❌ .profile does not initialize mise shims"
  exit 1
fi

if ! grep -Fq ". \"\$HOME/.profile\"" "$HOME/.bash_profile"; then
  echo "❌ .bash_profile does not load .profile"
  exit 1
fi

echo "✅ mise shims configured for login shells"

PROFILE_PATH=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" sh -c ". \"\$HOME/.profile\"; printf '%s\n' \"\$PATH\"")
case "$PROFILE_PATH" in
  "$HOME/.local/bin:"*) ;;
  *)
    echo "❌ .profile does not prepend ~/.local/bin to PATH"
    exit 1
    ;;
esac
PROFILE_LOCAL_BIN_COUNT=$(printf '%s\n' "$PROFILE_PATH" | tr ':' '\n' | grep -Fxc "$HOME/.local/bin" || true)
if [ "$PROFILE_LOCAL_BIN_COUNT" -ne 1 ]; then
  echo "❌ .profile adds ~/.local/bin to PATH more than once"
  exit 1
fi

BASHRC_PATH=$(env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/bin:/bin" bash -c ". \"\$HOME/.bashrc.d/00-path.sh\"; printf '%s\n' \"\$PATH\"")
BASHRC_LOCAL_BIN_COUNT=$(printf '%s\n' "$BASHRC_PATH" | tr ':' '\n' | grep -Fxc "$HOME/.local/bin" || true)
if [ "$BASHRC_LOCAL_BIN_COUNT" -ne 1 ]; then
  echo "❌ .bashrc.d/00-path.sh duplicates ~/.local/bin in PATH"
  exit 1
fi
echo "✅ ~/.local/bin PATH setup is idempotent"

TIMER_WANTS_LINK="$SYSTEMD_USER_DIR/timers.target.wants/chezmoi-update.timer"
if [ "$(cat "$SYSTEMD_USER_DIR/chezmoi-update.service")" != "local-service" ] \
  || [ "$(cat "$SYSTEMD_USER_DIR/chezmoi-update.timer")" != "local-timer" ] \
  || [ ! -L "$TIMER_WANTS_LINK" ] \
  || [ "$(readlink "$TIMER_WANTS_LINK")" != "../chezmoi-update.timer" ]; then
  echo "❌ existing unmanaged chezmoi updater systemd files were changed or removed"
  exit 1
fi
echo "✅ existing unmanaged chezmoi updater systemd files were preserved"

if [ ! -f "$HOME/.agents/skills/issue-pr/SKILL.md" ]; then
  echo "❌ Codex issue-pr skill not generated"
  exit 1
fi

if [ ! -x "$HOME/bin/gh-pr-target-repo.sh" ]; then
  echo "❌ gh-pr-target-repo helper not generated"
  exit 1
fi

if [ ! -x "$HOME/bin/powerline-daemon-launch.sh" ]; then
  echo "❌ powerline-daemon-launch helper not generated"
  exit 1
fi

if [ ! -x "$HOME/.agents/skills/pr-health-monitor/scripts/wait-for-copilot-review.sh" ]; then
  echo "❌ Codex Copilot review watcher script not generated"
  exit 1
fi

if [ ! -x "$HOME/.agents/skills/pr-health-monitor/scripts/pr-monitor-state.sh" ] \
  || [ ! -x "$HOME/.agents/skills/pr-health-monitor/scripts/watch-pr.sh" ] \
  || [ ! -f "$HOME/.agents/skills/resume-pr-monitor/SKILL.md" ]; then
  echo "❌ Durable Codex PR monitor files not generated"
  exit 1
fi

echo "✅ Codex files generated successfully"

# PR 後フローの skill 契約が chezmoi 展開後も保持されることを確認する。
PR_HEALTH_SKILL="$HOME/.agents/skills/pr-health-monitor/SKILL.md"
PR_CLOSE_SKILL="$HOME/.agents/skills/wait-for-pr-close/SKILL.md"
ISSUE_PR_SKILLS=(
  "$HOME/.agents/skills/issue-pr-deep/SKILL.md"
  "$HOME/.agents/skills/issue-pr-lite/SKILL.md"
)
GLITCHTIP_PR_SKILLS=(
  "$HOME/.agents/skills/glitchtip-pr-deep/SKILL.md"
  "$HOME/.agents/skills/glitchtip-pr-lite/SKILL.md"
)

if ! grep -Fq 'watch-pr.sh watch --pr-url' "$PR_HEALTH_SKILL" \
  || ! grep -Fq 'foreground_required' "$PR_HEALTH_SKILL" \
  || ! grep -Fq "\$resume-pr-monitor <PR_URL>" "$PR_HEALTH_SKILL" \
  || ! grep -Fq 'watcher は観測専用' "$PR_HEALTH_SKILL" \
  || ! grep -Fq '連続 5 回の API failure で停止する' "$PR_HEALTH_SKILL" \
  || ! grep -Fq 'GlitchTip callback descriptor は state に保存しない' "$PR_HEALTH_SKILL"; then
  echo "❌ Durable PR health monitor contract not generated"
  exit 1
fi

if ! grep -Fq 'watcher は PR state、checks、conflict、Copilot review を poll' "$PR_CLOSE_SKILL" \
  || ! grep -Fq "\$resume-pr-monitor <PR_URL>" "$PR_CLOSE_SKILL" \
  || ! grep -Fq 'durable state に保存しない' "$PR_CLOSE_SKILL" \
  || ! grep -Fq 'CLOSED' "$PR_CLOSE_SKILL"; then
  echo "❌ Durable PR close monitor contract not generated"
  exit 1
fi

for skill in "${ISSUE_PR_SKILLS[@]}"; do
  if ! grep -Fq "\$resume-pr-monitor <PR URL>" "$skill"; then
    echo "❌ Issue PR durable resume fallback missing in $skill"
    exit 1
  fi
done

for skill in "${GLITCHTIP_PR_SKILLS[@]}"; do
  if ! grep -Fq "\$pr-health-monitor <PR URL>" "$skill" \
    || ! grep -Fq "この flow で \`get_issue\` により取得した issue ID" "$skill" \
    || ! grep -Fq 'GlitchTip Issue: <permalink URL>' "$skill" \
    || ! grep -Fq "\$resume-pr-monitor <PR URL>" "$skill" \
    || ! grep -Fq "\`CLOSED\`" "$skill"; then
    echo "❌ GlitchTip PR callback flow not generated in $skill"
    exit 1
  fi
done

echo "✅ PR post-creation skill contracts generated successfully"

# PR 品質ゲート契約が chezmoi 展開後も保持されることを確認する。
ISSUE_PR_DISPATCHER="$HOME/.agents/skills/issue-pr/SKILL.md"
DEEP_REVIEW_SKILL="$HOME/.agents/skills/deep-review/SKILL.md"
CODEX_AGENTS="$HOME/.codex/AGENTS.md"

# 展開済み policy が fail-closed の判断を順序どおりに拘束することを確認する。
assert_ordered_policy() {
  local policy="$1" label="$2"
  shift 2
  local previous=0 offset pattern
  for pattern in "$@"; do
    offset=$(grep -boF "$pattern" "$policy" | awk -F: -v previous="$previous" '$1 > previous { print $1; exit }' || true)
    if [ -z "$offset" ] || [ "$offset" -le "$previous" ]; then
      echo "❌ $label does not enforce the required decision order: $pattern"
      exit 1
    fi
    previous=$offset
  done
}

for policy in "$ISSUE_PR_DISPATCHER" "${ISSUE_PR_SKILLS[@]}" "$CODEX_AGENTS"; do
  assert_ordered_policy "$policy" "PR monitoring precondition" \
    'canonical PR URL を取得するまで pane の登録、state/window の作成、watcher の起動をしない' \
    '永続的な terminal または resume fallback を選択できない場合は PR を作成せず停止する'
done

for skill in "${ISSUE_PR_SKILLS[@]}"; do
  assert_ordered_policy "$skill" "unchanged final-gate snapshot" \
    'tracked、staged、untracked と evidence ID を含む snapshot を 1 回記録する' \
    '最新の全検証を実行し' \
    '直後にシークレット確認を実行し' \
    '50 以上、P1、P2 の未解決指摘があれば停止する' \
    'diff、status、evidence を確認する' \
    'final evidence 確認後かつ commit/PR 作成直前に同じ snapshot と比較する' \
    '差分、status、evidence のいずれかが変われば最終ゲート全体を最初からやり直す'
done

assert_ordered_policy "$CODEX_AGENTS" "deployment final-gate snapshot" \
  'tracked、staged、untracked と evidence ID を含む snapshot を 1 回記録' \
  '各 substep 後と final evidence 確認後かつ commit/PR 作成直前に同じ snapshot と比較する' \
  'deployment assertion は、この reviewed snapshot に対して final evidence を確認した直後に限って行う' \
  'snapshot を再取得・更新してはならず' \
  '最終ゲート全体を最初からやり直す'

for policy in "$ISSUE_PR_DISPATCHER" "${ISSUE_PR_SKILLS[@]}" "$CODEX_AGENTS"; do
  if ! grep -Fq 'すべての Issue が一意、open、target repository 所属であることを検証する' "$policy" \
    || ! grep -Fq 'scope と acceptance criteria' "$policy" \
    || ! grep -Fq '文書' "$policy" \
    || ! grep -Fq 'review evidence' "$policy" \
    || ! grep -Fq 'closing keyword' "$policy" \
    || ! grep -Fq 'aggregate 最終ゲート' "$policy"; then
    echo "❌ Aggregate Issue evidence contract missing in $policy"
    exit 1
  fi
done

for policy in "$ISSUE_PR_DISPATCHER" "${ISSUE_PR_SKILLS[@]}" "$PR_HEALTH_SKILL" "$CODEX_AGENTS"; do
  # shellcheck disable=SC2016
  if ! grep -Fq 'canonical PR URL' "$policy" \
    || ! grep -Fq '失敗した stage' "$policy" \
    || ! grep -Eq 'fresh.*evidence' "$policy" \
    || ! grep -Eq '\$resume-pr-monitor <(PR_URL|canonical PR URL)>' "$policy"; then
    echo "❌ PR failure-report contract missing in $policy"
    exit 1
  fi
done

# shellcheck disable=SC2016
assert_ordered_policy "$PR_HEALTH_SKILL" "post-create monitor recovery" \
  'canonical `PR_URL`' \
  'pr-monitor-state.sh init --pr-url "$PR_URL"' \
  'register-pane --pr-url "$PR_URL"' \
  'watch-pr.sh start --pr-url "$PR_URL"' \
  'start が成功した後の initial CI/review observation が失敗しても watcher は active と報告する' \
  '初期観測の失敗は active な watcher と区別して報告する' \
  '$resume-pr-monitor <PR_URL>'

assert_ordered_policy "$DEEP_REVIEW_SKILL" "deep-review final-gate handoff" \
  'tracked、staged、untracked と evidence ID を含む snapshot を返す' \
  'final evidence 確認後かつ commit/PR 作成直前に同じ snapshot と比較する' \
  '差分、status、evidence のいずれかが変われば review を含む最終ゲート全体を最初からやり直す'

# shellcheck disable=SC2016
if ! grep -Fq '$issue-pr <Issue 番号または URL> [<Issue 番号または URL> ...]' "$ISSUE_PR_DISPATCHER" \
  || ! grep -Fq 'すべての入力を順序を保った `ISSUE_REFERENCES` 配列として解析する' "$ISSUE_PR_DISPATCHER" \
  || ! grep -Fq '各 `ISSUE_REFERENCE` を `gh issue view "$ISSUE_REFERENCE" --repo "$TARGET_REPOSITORY"` で取得する' "$ISSUE_PR_DISPATCHER" \
  || ! grep -Fq 'issue-pr-deep "${ISSUE_IDENTITIES[@]}" --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"' "$ISSUE_PR_DISPATCHER" \
  || ! grep -Fq 'issue-pr-lite "${ISSUE_IDENTITIES[@]}" --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"' "$ISSUE_PR_DISPATCHER"; then
  echo "❌ Issue PR dispatcher routing contract missing"
  exit 1
fi

echo "✅ PR quality-gate fail-closed decisions and recovery ordering verified"

# Superpowers plugin 依存除去の回帰テスト。
SUPERPOWERS_INVOCATIONS=(
  'superpowers:brainstorming'
  'superpowers:writing-plans'
  'superpowers:subagent-driven-development'
  'superpowers:executing-plans'
  'superpowers:verification-before-completion'
)
CLAUDE_WORKFLOW_SKILLS=(
  "$HOME/.claude/skills/issue-pr-deep/SKILL.md"
  "$HOME/.claude/skills/issue-pr-lite/SKILL.md"
  "$HOME/.claude/skills/glitchtip-pr-deep/SKILL.md"
  "$HOME/.claude/skills/glitchtip-pr-lite/SKILL.md"
)

for skill in "${CLAUDE_WORKFLOW_SKILLS[@]}"; do
  if [ ! -f "$skill" ]; then
    echo "❌ Expected active Claude workflow skill not deployed: $skill"
    exit 1
  fi
  for invocation in "${SUPERPOWERS_INVOCATIONS[@]}"; do
    if grep -Fq "$invocation" "$skill"; then
      echo "❌ Stale $invocation invocation still present in $skill"
      exit 1
    fi
  done
done

for rule in "$HOME/.claude/rules/"*.md; do
  for invocation in "${SUPERPOWERS_INVOCATIONS[@]}"; do
    if grep -Fq "$invocation" "$rule"; then
      echo "❌ Stale $invocation invocation still present in $rule"
      exit 1
    fi
  done
done

if [ -f "$HOME/.claude/rules/superpowers.md" ]; then
  echo "❌ deleted rules/superpowers.md still deployed"
  exit 1
fi

echo "✅ No superpowers: invocation remains in active Claude workflow"

# Superpowers plugin が展開後 settings.json (private_settings.json から生成) で
# enabled でないこと。
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo "❌ Claude Code settings.json not deployed"
  exit 1
fi
if grep -Fq '"superpowers@claude-plugins-official"' "$CLAUDE_SETTINGS"; then
  echo "❌ superpowers@claude-plugins-official is still enabled in settings.json"
  exit 1
fi

echo "✅ Superpowers plugin not enabled in deployed settings.json"

# .agent-work/ と legacy な docs/superpowers/ / .superpowers/ が
# global gitignore に残っていること (移行期間中の後方互換)。
GLOBAL_GITIGNORE="$XDG_CONFIG_HOME/git/ignore"
if ! grep -Fxq '.agent-work/' "$GLOBAL_GITIGNORE" \
  || ! grep -Fxq 'docs/superpowers/' "$GLOBAL_GITIGNORE" \
  || ! grep -Fxq '.superpowers/' "$GLOBAL_GITIGNORE"; then
  echo "❌ global gitignore missing .agent-work/ or legacy superpowers entries"
  exit 1
fi

echo "✅ global gitignore excludes .agent-work/ and legacy superpowers paths"

# deep path (issue-pr-deep / glitchtip-pr-deep) の自前 workflow 契約順序が
# 展開後も保持されること。
DEEP_WORKFLOW_SKILLS=(
  "$HOME/.claude/skills/issue-pr-deep/SKILL.md"
  "$HOME/.claude/skills/glitchtip-pr-deep/SKILL.md"
)
for skill in "${DEEP_WORKFLOW_SKILLS[@]}"; do
  # shellcheck disable=SC2016
  assert_ordered_policy "$skill" "self-hosted design-workflow contract order" \
    '## Phase 4: Review the Spec' \
    'Use **AskUserQuestion** to get explicit spec approval before Phase 7' \
    '## Phase 8: Review the Plan' \
    'Decide the execution approach yourself, per `rules/design-workflow.md`' \
    'Final Evidence Gate (Prompt-Only Contract)' \
    '## Phase 13: Deep Review'
done

echo "✅ Self-hosted deep workflow contract order preserved after deployment"

# lite path (issue-pr-lite / glitchtip-pr-lite) に Spec/Plan フェーズが存在せず、
# Final evidence gate と lite-review が保持されていること。
LITE_WORKFLOW_SKILLS=(
  "$HOME/.claude/skills/issue-pr-lite/SKILL.md"
  "$HOME/.claude/skills/glitchtip-pr-lite/SKILL.md"
)
for skill in "${LITE_WORKFLOW_SKILLS[@]}"; do
  if grep -Fq 'Write the Spec' "$skill" || grep -Fq 'Write the Plan' "$skill"; then
    echo "❌ lite path unexpectedly gained a Spec/Plan authoring phase: $skill"
    exit 1
  fi
  # shellcheck disable=SC2016
  if ! grep -Fq 'Final Evidence Gate' "$skill" \
    || ! grep -Fq 'Run `/lite-review` (no arguments' "$skill"; then
    echo "❌ lite path missing Final Evidence Gate / lite-review contract: $skill"
    exit 1
  fi
done

echo "✅ Lite workflow contract (no spec/plan, Final Evidence Gate + lite-review) preserved"

# Codex はプロジェクト信頼やフック承認ハッシュを config.toml に保存する。chezmoi の
# modify_ テンプレートが管理対象の設定を反映しつつ、その実行時状態を保持することを確認する。
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ ! -f "$CODEX_CONFIG" ]; then
  echo "❌ Codex config.toml not generated"
  exit 1
fi

sed -i '/^\[features\]$/a codex_hooks = false\nremote_control = true' "$CODEX_CONFIG"
sed -i '1i model = "gpt-5.4"' "$CODEX_CONFIG"
sed -i '1i model_reasoning_effort = "medium"' "$CODEX_CONFIG"
printf '\n[projects."/tmp/codex-runtime-state"]\ntrust_level = "trusted"\n[hooks.state."/tmp/codex-runtime-hook"]\ntrusted_hash = "sha256:test"\n[notice.model_migrations]\ngpt_5_4 = "gpt-5.6"\n' >> "$CODEX_CONFIG"
if ! "$CHEZMOI_BIN" apply --source="$SOURCE_DIR"; then
  echo "❌ chezmoi apply failed while preserving Codex runtime state"
  exit 1
fi

if ! grep -Fq 'web_search = "live"' "$CODEX_CONFIG" \
  || ! grep -Fq 'model = "gpt-5.4"' "$CODEX_CONFIG" \
  || ! grep -Fq 'model_reasoning_effort = "medium"' "$CODEX_CONFIG" \
  || ! grep -Fq 'hooks = true' "$CODEX_CONFIG" \
  || grep -Fq 'codex_hooks =' "$CODEX_CONFIG" \
  || ! grep -Fq 'remote_control = true' "$CODEX_CONFIG" \
  || ! grep -Fq 'trust_level = "trusted"' "$CODEX_CONFIG" \
  || ! grep -Fq 'trusted_hash = "sha256:test"' "$CODEX_CONFIG" \
  || ! grep -Fq 'gpt_5_4 = "gpt-5.6"' "$CODEX_CONFIG"; then
  echo "❌ Codex runtime state was not preserved"
  exit 1
fi

echo "✅ Codex runtime state preserved successfully"

# シークレットスキャン pre-commit フックの検証
if [ ! -x "$HOME/.config/git/hooks/pre-commit" ]; then
  echo "❌ pre-commit hook not generated or not executable"
  exit 1
fi

if [ ! -f "$HOME/.gitleaks.toml" ]; then
  echo "❌ .gitleaks.toml not generated"
  exit 1
fi

# git config --get はストア済みの生文字列を返し、~ はここでは展開されない (git 内部で
# フック解決時にのみ展開される) ため、リテラル文字列 "~/.config/git/hooks" と比較する
HOOKS_PATH_VALUE=$(git config --file "$HOME/.config/git/config" --get core.hooksPath || true)
# shellcheck disable=SC2088
if [ "$HOOKS_PATH_VALUE" != "~/.config/git/hooks" ]; then
  echo "❌ core.hooksPath not set to \$HOME/.config/git/hooks (got: $HOOKS_PATH_VALUE)"
  exit 1
fi

echo "✅ Secret scan pre-commit hook and hooksPath generated successfully"

# エンドツーエンド検証: 実際の git commit が core.hooksPath 経由でこのフックを起動すること
# (ユニットテストはフックスクリプトを bash 経由で直接呼び出すのみで、
# core.hooksPath の名前解決・実行権限を含む git 自身の起動経路は検証していないため)
HOOK_TEST_REPO=$(mktemp -d)
HOOK_MOCK_BIN=$(mktemp -d)
HOOK_INVOKED_MARKER=$(mktemp -u)
cat > "$HOOK_MOCK_BIN/gitleaks" << EOF
#!/bin/bash
touch "$HOOK_INVOKED_MARKER"
exit 0
EOF
chmod +x "$HOOK_MOCK_BIN/gitleaks"

(
  cd "$HOOK_TEST_REPO" || exit 1
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "content" > file.txt
  git add file.txt
  PATH="$HOOK_MOCK_BIN:$PATH" git commit -q -m "test commit"
)
HOOK_COMMIT_EXIT=$?

if [ "$HOOK_COMMIT_EXIT" -ne 0 ]; then
  echo "❌ git commit failed unexpectedly (exit $HOOK_COMMIT_EXIT)"
  rm -rf "$HOOK_TEST_REPO" "$HOOK_MOCK_BIN"
  exit 1
fi

if [ ! -f "$HOOK_INVOKED_MARKER" ]; then
  echo "❌ pre-commit hook was not invoked by git via core.hooksPath"
  rm -rf "$HOOK_TEST_REPO" "$HOOK_MOCK_BIN"
  exit 1
fi

rm -rf "$HOOK_TEST_REPO" "$HOOK_MOCK_BIN" "$HOOK_INVOKED_MARKER"
echo "✅ pre-commit hook invoked by git via core.hooksPath end-to-end"

CODEX_AGENT_FILES=(
  "spec_reviewer.toml"
  "plan_reviewer.toml"
  "container_status_checker.toml"
  "container_error_investigator.toml"
)

for agent_file in "${CODEX_AGENT_FILES[@]}"; do
  if [ ! -f "$HOME/.codex/agents/$agent_file" ]; then
    echo "❌ Codex agent definition not generated: $agent_file"
    exit 1
  fi
done

echo "✅ Codex agent definitions generated successfully"

# Idempotency テスト: 2 回目の apply で差分がないことを確認
echo "Testing idempotency..."
# .chezmoiscripts/ ディレクトリの変更は無視 (chezmoi の内部管理ファイル)
DIFF_OUTPUT=$("$CHEZMOI_BIN" diff --source="$SOURCE_DIR" 2>&1 | awk '
  BEGIN { skip = 0 }
  /^diff --git a\/.chezmoiscripts\// { skip = 1; next }
  /^diff --git/ { skip = 0 }
  !skip { print }
')
if [ -n "$DIFF_OUTPUT" ]; then
  echo "❌ Idempotency test failed: chezmoi diff showed changes after apply"
  echo "$DIFF_OUTPUT"
  exit 1
fi

echo "✅ Idempotency test passed"

# シンボリックリンクの整合性確認 (Claude Code フックのシンボリックリンク)
HOOKS_DIR="$HOME/.claude/hooks"
SYMLINKS=(
  "code-review-immediate-fix.sh"
  "require-code-review-fixes.sh"
  "require-review-thread-fixes.sh"
)

SYMLINK_CHECKED=0
for symlink in "${SYMLINKS[@]}"; do
  SYMLINK_PATH="$HOOKS_DIR/$symlink"
  if [ -L "$SYMLINK_PATH" ]; then
    TARGET=$(readlink "$SYMLINK_PATH")
    if [ ! -f "$HOOKS_DIR/$TARGET" ]; then
      echo "❌ Symlink broken: $symlink -> $TARGET"
      exit 1
    fi
    echo "✅ Symlink integrity verified: $symlink -> $TARGET"
    SYMLINK_CHECKED=$((SYMLINK_CHECKED + 1))
  fi
done

if [ $SYMLINK_CHECKED -gt 0 ]; then
  echo "✅ All $SYMLINK_CHECKED symlinks verified"
fi

# 環境変数テンプレートの検証
if [ -f "$HOME/.env.example" ] && [ ! -f "$HOME/.env" ]; then
  echo "✅ Template files correctly generated (not applied)"
fi

echo "✅ All integration tests passed"
