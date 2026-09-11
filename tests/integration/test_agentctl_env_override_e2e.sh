#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015: `check && pass || fail` は本テストの意図通り。
#
# inherited Git environment override を実 Codex PreToolUse で検証する。
# disposable repo の control commit が通常は許可されることを先に確認し、同じ操作へ
# GIT_DIR/GIT_WORK_TREE を継承した場合だけ managed dispatcher が変更前に拒否することを確認する。
# production/user repository は fixture に使わない。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v git >/dev/null 2>&1 || { echo "⚠️  git not found; skipping env override live E2E"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping env override live E2E"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping env override live E2E"; exit 0; }
command -v codex >/dev/null 2>&1 || { echo "⚠️  codex CLI not found; skipping env override live E2E"; exit 0; }
if ! timeout 10 codex login status >/dev/null 2>&1; then
  echo "⚠️  codex CLI not authenticated; skipping env override live E2E"
  exit 0
fi

# managed hook の実配備内容そのものを前提条件として検証する。
if ! HOME="$HOME" bash -c '
  source "$1/home/bin/agentctl-common.sh"
  source "$1/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_preflight
' _ "$REPO_ROOT" >/dev/null 2>&1; then
  fail "deployed Codex hook/preflight is stale; real env-override E2E cannot prove the managed guard"
  exit "$FAILED"
fi

WORKROOT=$(mktemp -d)
ORIG_PATH=$PATH
REAL_TMUX=$(command -v tmux)
TMUX_SOCKET="agentctl-envoverride-e2e-$$"

cleanup_all() {
  PATH="$ORIG_PATH" "$REAL_TMUX" -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

for repo_name in allowed override; do
  mkdir -p "$WORKROOT/$repo_name"
  git -C "$WORKROOT/$repo_name" init -q -b main
  git -C "$WORKROOT/$repo_name" config user.email test@example.com
  git -C "$WORKROOT/$repo_name" config user.name test
  git -C "$WORKROOT/$repo_name" -c core.hooksPath=/dev/null commit -q --allow-empty -m init
done

RUNTIME_DIR="$WORKROOT/runtime"
mkdir -p "$RUNTIME_DIR" "$WORKROOT/tmux" "$WORKROOT/bin"
GCD=$(git -C "$WORKROOT/allowed" rev-parse --path-format=absolute --git-common-dir)
POLICY="$RUNTIME_DIR/policy.snapshot.json"
jq -n --arg gcd "$GCD" '
{
  version:1,
  permissions:{local_write:true,commit:true,push:false,create_pr:false,merge:false,git_cleanup:false,deploy:false,production_verify:false},
  scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[]}],remotes:[],production_targets:[]}
}' >"$POLICY"
POLICY_DIGEST=$(jq -S -c . "$POLICY" | sha256sum | awk '{print "sha256:" $1}')
RUNTIME_ID="envoverride-$$"
jq -n --arg rid "$RUNTIME_ID" --arg cwd "$REPO_ROOT" \
  '{schema_version:1,name:"envoverride",backend:"codex",runtime_id:$rid,cwd:$cwd,status:"running"}' \
  >"$RUNTIME_DIR/state.json"

cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L "$TMUX_SOCKET" "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"
export TMUX_TMPDIR="$WORKROOT/tmux"
unset TMUX || true

tmux new-session -d -s envoverride -c "$REPO_ROOT"
PANE=$(tmux display-message -p -t envoverride '#{pane_id}')
tmux set-option -p -t "$PANE" @agentctl_owner agentctl
tmux set-option -p -t "$PANE" @agentctl_name envoverride
tmux set-option -p -t "$PANE" @agentctl_runtime_id "$RUNTIME_ID"
tmux set-option -p -t "$PANE" @agentctl_backend codex
tmux set-option -p -t "$PANE" @agentctl_schema_version 1

run_codex_exact() {
  local prompt="$1" stdout_file="$2" stderr_file="$3"
  shift 3
  HOME="$HOME" TMUX_PANE="$PANE" \
    AGENTCTL_POLICY_SNAPSHOT="$POLICY" \
    AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" \
    AGENTCTL_RUNTIME_ID="$RUNTIME_ID" \
    "$@" timeout 75 codex exec -s danger-full-access -c features.unified_exec=false \
      "$prompt" </dev/null >"$stdout_file" 2>"$stderr_file"
}

CONTROL_BEFORE=$(git -C "$WORKROOT/allowed" rev-list --count HEAD)
CONTROL_PROMPT="Execute exactly this command and nothing else: git -C $WORKROOT/allowed commit --allow-empty -m env-control"
if run_codex_exact "$CONTROL_PROMPT" "$WORKROOT/control.out" "$WORKROOT/control.err" env; then
  :
fi
CONTROL_AFTER=$(git -C "$WORKROOT/allowed" rev-list --count HEAD)
[ "$CONTROL_AFTER" -eq $((CONTROL_BEFORE + 1)) ] \
  && pass "real Codex PreToolUse allows the otherwise-approved disposable commit (control)" \
  || fail "control commit did not execute; cannot prove the override-specific deny ($(tail -20 "$WORKROOT/control.err" 2>/dev/null))"

ALLOWED_BEFORE=$(git -C "$WORKROOT/allowed" rev-parse HEAD)
OVERRIDE_BEFORE=$(git -C "$WORKROOT/override" rev-parse HEAD)
DENY_PROMPT="Execute exactly this command and nothing else: git -C $WORKROOT/allowed commit --allow-empty -m should-be-blocked"
if run_codex_exact "$DENY_PROMPT" "$WORKROOT/deny.out" "$WORKROOT/deny.err" \
    env GIT_DIR="$WORKROOT/override/.git" GIT_WORK_TREE="$WORKROOT/override"; then
  :
fi
ALLOWED_AFTER=$(git -C "$WORKROOT/allowed" rev-parse HEAD)
OVERRIDE_AFTER=$(git -C "$WORKROOT/override" rev-parse HEAD)

grep -qF 'Command blocked by PreToolUse hook: agentctl policy denied this operation (classification: deny)' "$WORKROOT/deny.err" \
  && pass "real Codex PreToolUse mechanically denies the otherwise-allowed commit when inherited Git overrides are present" \
  || fail "did not observe the managed PreToolUse policy deny for inherited Git overrides"
[ "$ALLOWED_BEFORE" = "$ALLOWED_AFTER" ] && [ "$OVERRIDE_BEFORE" = "$OVERRIDE_AFTER" ] \
  && pass "denied inherited override operation leaves both disposable repositories unchanged" \
  || fail "a repository changed despite the inherited override deny"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl env override live E2E tests passed."
else
  echo "Some agentctl env override live E2E tests FAILED."
fi
exit "$FAILED"
