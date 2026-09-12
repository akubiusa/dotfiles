#!/bin/bash
# shellcheck disable=SC2015,SC2329,SC2317
# SC2317: trap/mock 経由で間接実行する関数本体を旧ShellCheckが到達不能と誤検知する。
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
#
# guard startup verification を実 Claude backend で確認する live E2E。
# settings JSON を書いた/dispatcher を script として直接呼んだだけでは、
# 実 Claude process が実際に PreToolUse hook を load して発火させる保証には
# ならない。ここでは agentctl start の実運用経路をそのまま使い、無害な
# sentinel command が real Claude turn 経由で実 PreToolUse として発火し、
# agentctl-policy-dispatcher.sh が deny evidence を書くことを機械的に確認する
# (tests/unit/test_agentctl_dispatcher.sh の marker/schema fail-closed テスト、
# tests/unit/test_agentctl_backends.sh の checksum fail-closed テストは script
# 単体呼び出しの静的検証であり、この live E2E はその先にある「実 process が
# 本当に hook を load したか」を証明する)。
#
# 実 Claude CLI に認証済み credential が必要なため、claude バイナリが無い/
# 疎通できない環境では gracefully skip する ("where feasible" — CI 等
# credential の無い環境まで必須にはしない)。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping guard sentinel live E2E"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping guard sentinel live E2E"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "⚠️  claude CLI not found; skipping guard sentinel live E2E"; exit 0; }
timeout 20 claude -p "reply with exactly: ok" >/tmp/agentctl-sentinel-e2e-probe.out 2>&1
if ! grep -qi "ok" /tmp/agentctl-sentinel-e2e-probe.out; then
  echo "⚠️  claude CLI not authenticated/reachable; skipping guard sentinel live E2E"
  rm -f /tmp/agentctl-sentinel-e2e-probe.out
  exit 0
fi
rm -f /tmp/agentctl-sentinel-e2e-probe.out

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-sentinel-e2e-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"

cleanup_all() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

mkdir -p "$WORKROOT/worktree"
POLICY="$WORKROOT/policy.json"
cat >"$POLICY" <<JSON
{"version":1,"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false},"scope":{"repositories":[{"id":"primary","git_common_dir":"/nonexistent/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}],"remotes":[],"production_targets":[]}}
JSON

RID=$(timeout 90 bash "$AGENTCTL" start --name e2eclaude --cwd "$WORKROOT/worktree" --backend claude --policy-file "$POLICY" --mission-stdin <<<"Say hello and then stop, do nothing else." 2>"$WORKROOT/start-err")
START_RC=$?

[ "$START_RC" -eq 0 ] && [ -n "$RID" ] && pass "agentctl start (real Claude backend) publishes a runtime after passing guard sentinel verification" \
  || fail "agentctl start with real Claude backend failed: rc=$START_RC $(cat "$WORKROOT/start-err" 2>/dev/null)"

EVIDENCE="$WORKROOT/state/agentctl/runtimes/e2eclaude/guard-sentinel.json"
if [ -f "$EVIDENCE" ]; then
  EV_RID=$(jq -r '.runtime_id' "$EVIDENCE")
  EV_DECISION=$(jq -r '.decision' "$EVIDENCE")
  [ "$EV_RID" = "$RID" ] && [ "$EV_DECISION" = "deny" ] \
    && pass "real PreToolUse hook fired for the sentinel probe and the dispatcher recorded a deny (mechanical proof, not just config grep)" \
    || fail "guard sentinel evidence present but does not match this generation (runtime_id=$EV_RID decision=$EV_DECISION expected runtime_id=$RID decision=deny)"
else
  fail "guard sentinel evidence file was never written; real Claude process did not demonstrably load the PreToolUse guard"
fi

RECONCILE=$(bash "$AGENTCTL" status --name e2eclaude --json 2>/dev/null | jq -r '.reconcile')
[ "$RECONCILE" = "running" ] && pass "runtime remains running (mission delivery proceeded normally after guard sentinel verification succeeded)" \
  || fail "expected reconcile=running after successful guard sentinel verification, got: $RECONCILE"

bash "$AGENTCTL" stop --name e2eclaude --runtime-id "$RID" >/dev/null 2>&1 || true
bash "$AGENTCTL" cleanup --name e2eclaude --runtime-id "$RID" >/dev/null 2>&1 || true

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl guard sentinel live E2E tests passed."
else
  echo "Some agentctl guard sentinel live E2E tests FAILED."
fi
exit "$FAILED"
