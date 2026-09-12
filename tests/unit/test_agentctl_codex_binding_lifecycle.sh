#!/bin/bash
# Codex runtime の stop/complete が persistent app-server binding を失効させることを検証する。
# shellcheck disable=SC1090,SC1091,SC2329
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT
export HOME="$WORKROOT/home" XDG_STATE_HOME="$WORKROOT/state"
mkdir -p "$HOME" "$XDG_STATE_HOME"
source "$REPO_ROOT/home/bin/executable_agentctl"
FAILED=0
pass(){ echo "✅ $*"; }
fail(){ echo "❌ $*"; FAILED=1; }
NAME=codexlife
RID=11111111-2222-4333-8444-555555555555
STATE='{"schema_version":1,"name":"codexlife","backend":"codex","runtime_id":"'$RID'","cwd":"/tmp","tmux_session":"agentctl-codexlife","tmux_socket_path":"/tmp/agentctl-codexlife.sock","status":"running"}'
REMOVE_MARKER="$WORKROOT/removed"
WRITE_MARKER="$WORKROOT/state-written"
agentctl_reconcile(){ echo running; }
agentctl_read_state(){ printf '%s\n' "$STATE"; }
agentctl_read_manifest(){ printf '%s\n' '{"mission_status":"done"}'; }
agentctl_tmux(){ [ "${1:-}" = kill-session ] && return 0; return 0; }
agentctl_codex_hook_remove_runtime_bindings(){ printf '%s' "$1" >"$REMOVE_MARKER"; }
agentctl_write_state_json(){ cat >"$WRITE_MARKER"; }

_stop_locked "$NAME" "$RID" >/dev/null
if [ "$(cat "$REMOVE_MARKER" 2>/dev/null)" = "$RID" ] && [ "$(jq -r '.status' "$WRITE_MARKER" 2>/dev/null)" = stopped ]; then
  pass "stop revokes Codex session binding and marks state stopped after tmux termination"
else
  fail "stop did not revoke binding/update state"
fi
rm -f "$REMOVE_MARKER" "$WRITE_MARKER"
KILL_MARKER="$WORKROOT/killed"
agentctl_reconcile(){ echo exited; }
agentctl_tmux(){ if [ "${1:-}" = kill-session ]; then printf '%s\n' "$*" >"$KILL_MARKER"; fi; return 0; }
_stop_locked "$NAME" "$RID" >/dev/null
if [ -s "$KILL_MARKER" ] && [ "$(cat "$REMOVE_MARKER" 2>/dev/null)" = "$RID" ] && [ "$(jq -r '.status' "$WRITE_MARKER" 2>/dev/null)" = stopped ]; then
  pass "stop removes an exited owner tmux session before revoking binding and terminalizing state"
else
  fail "stop left an exited owner tmux session behind"
fi
rm -f "$REMOVE_MARKER" "$WRITE_MARKER" "$KILL_MARKER"
agentctl_reconcile(){ echo running; }
agentctl_tmux(){ [ "${1:-}" = kill-session ] && return 0; return 0; }
_complete_locked "$NAME" "$RID" >/dev/null
if [ "$(cat "$REMOVE_MARKER" 2>/dev/null)" = "$RID" ] && [ "$(jq -r '.status' "$WRITE_MARKER" 2>/dev/null)" = completed ]; then
  pass "complete revokes Codex session binding and marks state completed after tmux termination"
else
  fail "complete did not revoke binding/update state"
fi

[ "$FAILED" -eq 0 ] && echo "agentctl Codex binding lifecycle tests: PASS" || echo "agentctl Codex binding lifecycle tests: FAIL"
exit "$FAILED"
