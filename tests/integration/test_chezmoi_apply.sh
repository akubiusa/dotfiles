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
