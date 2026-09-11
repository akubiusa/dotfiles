#!/bin/bash
# shellcheck disable=SC2015,SC2329
# attach の lock 解放後に同名 generation が置換されても、旧 runtime_id client が
# new generation へ接続できないことを exact tmux evidence で検証する。
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"
FAILED=0
pass() { echo "✅ $*"; }
fail() { echo "❌ $*"; FAILED=1; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping attach fencing test"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping attach fencing test"; exit 0; }

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR" "$WORKROOT/bin" "$WORKROOT/worktree" "$WORKROOT/repo/.git"
unset TMUX || true
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-attach-fence-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"
trap 'tmux kill-server >/dev/null 2>&1 || true; rm -rf "$WORKROOT"' EXIT

POLICY="$WORKROOT/policy.json"
jq -n --arg gcd "$WORKROOT/repo/.git" --arg root "$WORKROOT/worktree" \
  '{version:1,permissions:{local_write:true,commit:false,push:false,create_pr:false,merge:false,git_cleanup:false,deploy:false,production_verify:false},scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[$root]}],remotes:[],production_targets:[]}}' >"$POLICY"

NAME="attachrace"
RID_OLD=$(bash "$AGENTCTL" start "$NAME" --agent fake --cwd "$WORKROOT/worktree" --policy-file "$POLICY" --mission-stdin <<<"old")
EVIDENCE=$(bash -c 'source "$1"; set +e; agentctl_with_name_lock "$2" _attach_check "$2" "$3"' _ "$AGENTCTL" "$NAME" "$RID_OLD")
OLD_SESSION_ID=${EVIDENCE%%$'\t'*}
OLD_PANE=${EVIDENCE#*$'\t'}

bash "$AGENTCTL" stop "$NAME" --runtime-id "$RID_OLD" >/dev/null
bash "$AGENTCTL" cleanup "$NAME" --runtime-id "$RID_OLD" >/dev/null
RID_NEW=$(bash "$AGENTCTL" start "$NAME" --agent fake --cwd "$WORKROOT/worktree" --policy-file "$POLICY" --mission-stdin <<<"new")
NEW_SESSION="agentctl-$NAME"

set +e
bash -c 'source "$1"; set +e; agentctl_attach_fenced "$2" "$3" "$4"' _ \
  "$AGENTCTL" "$OLD_SESSION_ID" "$OLD_PANE" "$RID_OLD" >"$WORKROOT/stale.out" 2>"$WORKROOT/stale.err"
RC=$?
set -u
CLIENTS=$(tmux list-clients -t "$NEW_SESSION" 2>/dev/null | wc -l)
if [ "$RC" -eq 4 ] && [ "$CLIENTS" -eq 0 ]; then
  pass "stale attach evidence cannot connect to a replacement generation with the same logical name"
else
  fail "stale attach fencing failed (rc=$RC clients_on_new=$CLIENTS evidence=$EVIDENCE err=$(cat "$WORKROOT/stale.err" 2>/dev/null))"
fi

bash "$AGENTCTL" stop "$NAME" --runtime-id "$RID_NEW" >/dev/null
bash "$AGENTCTL" cleanup "$NAME" --runtime-id "$RID_NEW" >/dev/null

[ "$FAILED" -eq 0 ] && echo "agentctl attach fencing test: PASS" || echo "agentctl attach fencing test: FAIL"
exit "$FAILED"
