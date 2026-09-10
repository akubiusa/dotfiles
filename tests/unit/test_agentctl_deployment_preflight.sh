#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
# agentctl-deployment-preflight の read-only 判定テスト。
# 稼働中 runtime が無ければ exit 0、あれば exit 1 で拒否し、
# runtime 自体には一切手を触れない (stop/kill しない) ことを検証する。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"
PREFLIGHT="$REPO_ROOT/home/bin/executable_agentctl-deployment-preflight"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping preflight tests"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping preflight tests"; exit 0; }

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-preflight-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"

cleanup_all() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

REPO_FIXTURE="$WORKROOT/repo"
mkdir -p "$REPO_FIXTURE/.git" "$WORKROOT/worktree"
POLICY="$WORKROOT/policy.json"
cat >"$POLICY" <<JSON
{"schema_version":1,"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false},"repository":{"git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}}
JSON

if bash "$PREFLIGHT" >/tmp/agentctl-preflight-out 2>&1; then
  pass "preflight allows rollback when no runtimes exist"
else
  fail "preflight should succeed with no runtimes: $(cat /tmp/agentctl-preflight-out)"
fi

RID=$(bash "$AGENTCTL" start --name pf1 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission")

if bash "$PREFLIGHT" >/tmp/agentctl-preflight-out2 2>&1; then
  fail "preflight should refuse rollback while runtime pf1 is running"
else
  grep -q "pf1" /tmp/agentctl-preflight-out2 && pass "preflight refuses rollback and names the blocking runtime" \
    || fail "preflight rejection did not name blocking runtime: $(cat /tmp/agentctl-preflight-out2)"
fi

RECONCILE_AFTER=$(bash "$AGENTCTL" status --name pf1 --json | jq -r '.reconcile')
[ "$RECONCILE_AFTER" = "running" ] && pass "preflight is read-only: runtime pf1 still running after refusal" \
  || fail "preflight must never stop/kill runtimes, but reconcile=$RECONCILE_AFTER"

bash "$AGENTCTL" stop --name pf1 --runtime-id "$RID" >/dev/null

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-deployment-preflight unit tests passed."
else
  echo "Some agentctl-deployment-preflight unit tests FAILED."
fi
exit "$FAILED"
