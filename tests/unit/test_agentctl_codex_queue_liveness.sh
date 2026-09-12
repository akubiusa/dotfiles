#!/bin/bash
# Codex queue用session bindingはowner tmux generationがliveな間だけ解決できることを検証する。
# shellcheck disable=SC2015
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=/dev/null
source "$REPO_ROOT/home/bin/agentctl-common.sh"
FAILED=0
pass(){ echo "✅ $*"; }
fail(){ echo "❌ $*"; FAILED=1; }
command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping Codex queue liveness test"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping Codex queue liveness test"; exit 0; }
WORKROOT=$(mktemp -d)
export HOME="$WORKROOT/home" XDG_STATE_HOME="$WORKROOT/state" TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$HOME" "$TMUX_TMPDIR" "$WORKROOT/bin" "$WORKROOT/runtime" "$WORKROOT/cwd"
unset TMUX || true
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-queue-live-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"
trap 'tmux kill-server >/dev/null 2>&1 || true; rm -rf "$WORKROOT"' EXIT

RID=11111111-2222-4333-8444-666666666666
NAME=queuelive
SID=01a00000-aaaa-bbbb-cccc-dddddddddddd
SESSION="agentctl-$NAME"
POLICY="$WORKROOT/runtime/policy.snapshot.json"
printf '%s\n' '{"version":1}' >"$POLICY"
DIGEST="sha256:$(jq -S -c . "$POLICY" | sha256sum | awk '{print $1}')"

tmux new-session -d -s "$SESSION" -- sleep 300
tmux set-option -t "$SESSION" remain-on-exit on >/dev/null
PANE=$(tmux display-message -p -t "$SESSION" '#{pane_id}')
SOCKET=$(tmux display-message -p -t "$SESSION" '#{socket_path}')
PID=$(tmux display-message -p -t "$SESSION" '#{pane_pid}')
PID_START=$(agentctl_pid_start_token "$PID")
tmux set-option -p -t "$PANE" @agentctl_owner agentctl
tmux set-option -p -t "$PANE" @agentctl_name "$NAME"
tmux set-option -p -t "$PANE" @agentctl_backend codex
tmux set-option -p -t "$PANE" @agentctl_runtime_id "$RID"
tmux set-option -p -t "$PANE" @agentctl_schema_version "$AGENTCTL_SCHEMA_VERSION"

jq -n --arg rid "$RID" --arg name "$NAME" --arg cwd "$WORKROOT/cwd" --arg session "$SESSION" \
  --arg socket "$SOCKET" --arg pane "$PANE" --argjson pid "$PID" --arg start "$PID_START" \
  --arg policy "$POLICY" --arg digest "$DIGEST" \
  '{schema_version:1,name:$name,backend:"codex",runtime_id:$rid,cwd:$cwd,tmux_session:$session,
    tmux_socket_path:$socket,pane_id:$pane,pane_pid:$pid,pane_pid_start:$start,
    policy_snapshot_path:$policy,policy_digest:$digest,status:"running"}' >"$WORKROOT/runtime/state.json"
agentctl_codex_hook_registry_ensure
KEY=$(agentctl_codex_hook_key "$SID")
jq -n --arg sid "$SID" --arg rid "$RID" --arg name "$NAME" --arg dir "$WORKROOT/runtime" \
  --arg cwd "$WORKROOT/cwd" --arg policy "$POLICY" --arg digest "$DIGEST" \
  '{schema_version:1,session_id:$sid,runtime_id:$rid,name:$name,backend:"codex",runtime_dir:$dir,
    policy_snapshot:$policy,policy_digest:$digest,cwd:$cwd}' >"$(agentctl_codex_hook_sessions_dir)/$KEY.json"

RESOLVED=$(agentctl_codex_hook_session_id_for_runtime "$RID" "$WORKROOT/runtime" 2>/dev/null || true)
[ "$RESOLVED" = "$SID" ] \
  && pass "Codex queue session resolves while its exact tmux generation is live" \
  || fail "live Codex queue session did not resolve: $RESOLVED"

tmux kill-session -t "$SESSION" >/dev/null
RESOLVED_AFTER=$(agentctl_codex_hook_session_id_for_runtime "$RID" "$WORKROOT/runtime" 2>/dev/null || true)
[ -z "$RESOLVED_AFTER" ] \
  && pass "Codex queue session is refused after owner tmux generation exits" \
  || fail "stale Codex queue session still resolved after owner generation exit: $RESOLVED_AFTER"

[ "$FAILED" -eq 0 ] && echo "agentctl Codex queue liveness tests: PASS" || echo "agentctl Codex queue liveness tests: FAIL"
exit "$FAILED"
