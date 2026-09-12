#!/bin/bash
# shellcheck disable=SC2015
# stateに固定したtmux socketがcaller環境と異なってもruntime controlがowner serverを使うことを検証する。
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"
command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping socket lifecycle test"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping socket lifecycle test"; exit 0; }
FAILED=0; pass(){ echo "✅ $*"; }; fail(){ echo "❌ $*"; FAILED=1; }
WORKROOT=$(mktemp -d); trap '"$REAL_TMUX" -L agentctl-socket-life kill-server >/dev/null 2>&1 || true; rm -rf "$WORKROOT"' EXIT
export XDG_STATE_HOME="$WORKROOT/state" TMUX_TMPDIR="$WORKROOT/tmux"; mkdir -p "$TMUX_TMPDIR" "$WORKROOT/wrap" "$WORKROOT/worktree" "$WORKROOT/repo/.git"
unset TMUX || true
REAL_TMUX=$(command -v tmux); REAL_PATH="$PATH"
cat >"$WORKROOT/wrap/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-socket-life "\$@"
WRAP
chmod +x "$WORKROOT/wrap/tmux"
POLICY="$WORKROOT/policy.json"
jq -n --arg gcd "$WORKROOT/repo/.git" --arg root "$WORKROOT/worktree" '{version:1,permissions:{local_write:true,commit:false,push:false,create_pr:false,merge:false,git_cleanup:false,deploy:false,production_verify:false},scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[$root]}],remotes:[],production_targets:[]}}' >"$POLICY"
NAME=socklife
RID=$(PATH="$WORKROOT/wrap:$REAL_PATH" bash "$AGENTCTL" start "$NAME" --agent fake --cwd "$WORKROOT/worktree" --policy-file "$POLICY" --mission-stdin <<<"socket mission")
STATE="$XDG_STATE_HOME/agentctl/runtimes/$NAME/state.json"
SOCKET=$(jq -r '.tmux_socket_path' "$STATE")
# wrapperを外したcallerはdefault serverを見られない。それでもstate socketでrunningを解決する。
REC=$(PATH="$REAL_PATH" bash "$AGENTCTL" status "$NAME" --json | jq -r '.reconcile')
[ "$REC" = running ] && pass "status resolves a runtime through its recorded tmux socket from a different caller environment" || fail "status misreconciled custom-socket runtime: $REC"
PATH="$REAL_PATH" bash "$AGENTCTL" steer "$NAME" --runtime-id "$RID" --stdin <<<"socket steer" >/dev/null \
  && pass "steer targets the recorded tmux socket" || fail "steer failed across tmux socket boundary"
LOGS=$(PATH="$REAL_PATH" bash "$AGENTCTL" logs "$NAME" --lines 100 2>/dev/null || true)
echo "$LOGS" | grep -q 'socket steer' && pass "logs targets the recorded tmux socket" || fail "logs missed custom-socket pane"
PATH="$REAL_PATH" bash "$AGENTCTL" stop "$NAME" --runtime-id "$RID" >/dev/null \
  && pass "stop targets the recorded tmux socket" || fail "stop failed across tmux socket boundary"
if "$REAL_TMUX" -S "$SOCKET" has-session -t "=agentctl-$NAME" >/dev/null 2>&1; then
  fail "stop left owner session alive on recorded socket"
else
  pass "stop removed the owner session from the recorded socket"
fi
PATH="$REAL_PATH" bash "$AGENTCTL" cleanup "$NAME" --runtime-id "$RID" >/dev/null \
  && pass "cleanup succeeds from a different tmux caller environment" || fail "cleanup failed across tmux socket boundary"
[ "$FAILED" -eq 0 ] && echo "agentctl tmux socket lifecycle tests: PASS" || echo "agentctl tmux socket lifecycle tests: FAIL"
exit "$FAILED"
