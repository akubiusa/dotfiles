#!/bin/bash
# shellcheck disable=SC2015,SC2329
# sentinel verification failure 時の generation rollback 順序を検証する。
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=/dev/null
source "$REPO_ROOT/home/bin/executable_agentctl"
set +e

FAILED=0
pass() { echo "✅ $*"; }
fail() { echo "❌ $*"; FAILED=1; }
WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT
STATE_FILE="$WORKROOT/state.json"
REMOVED_BINDING="$WORKROOT/binding-removed"
printf '{"runtime_id":"new"}\n' >"$STATE_FILE"

agentctl_state_file() { printf '%s\n' "$STATE_FILE"; }
agentctl_write_state_json() { cat >"$STATE_FILE"; }
agentctl_codex_hook_remove_runtime_bindings() { : >"$REMOVED_BINDING"; }
agentctl_tmux() {
  [ "${1:-}" = "kill-session" ] || return 0
  return 1
}

( _rollback_failed_guard_generation codex test-session rt-test new-runtime "" ) \
  >/dev/null 2>"$WORKROOT/kill-fail.err"
RC=$?
if [ "$RC" -eq 5 ] && [ -f "$STATE_FILE" ] && [ ! -e "$REMOVED_BINDING" ]; then
  pass "sentinel rollback preserves state and Codex binding when owned session termination fails"
else
  fail "sentinel rollback changed evidence after kill failure (rc=$RC state=$([ -f "$STATE_FILE" ] && echo yes || echo no) binding_removed=$([ -e "$REMOVED_BINDING" ] && echo yes || echo no))"
fi

agentctl_tmux() { return 0; }
rm -f "$REMOVED_BINDING"
printf '{"runtime_id":"new"}\n' >"$STATE_FILE"
_rollback_failed_guard_generation codex test-session rt-test new-runtime "" >/dev/null 2>"$WORKROOT/kill-ok.err"
RC=$?
if [ "$RC" -eq 0 ] && [ ! -f "$STATE_FILE" ] && [ -e "$REMOVED_BINDING" ]; then
  pass "sentinel rollback removes binding/state only after owned session termination succeeds"
else
  fail "sentinel rollback did not clean evidence after successful termination (rc=$RC)"
fi

printf '{"runtime_id":"new"}\n' >"$STATE_FILE"
PREDECESSOR='{"runtime_id":"old","status":"stale"}'
_rollback_failed_guard_generation claude test-session rt-test new-runtime "$PREDECESSOR" >/dev/null 2>"$WORKROOT/restore.err"
if [ "$(cat "$STATE_FILE")" = "$PREDECESSOR" ]; then
  pass "sentinel rollback restores predecessor state after successful termination"
else
  fail "sentinel rollback failed to restore predecessor state"
fi

# release token の respawn-pane 自体が nonzero の場合も、backend が部分的に起動済みかも
# しれないため未検証 generation を rollback して exit 5 にする。
RESPAWN_ROLLBACK_MARKER="$WORKROOT/respawn-rollback"
agentctl_tmux() {
  [ "${1:-}" = "respawn-pane" ] && return 1
  return 0
}
_rollback_failed_guard_generation() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$RESPAWN_ROLLBACK_MARKER"
  return 0
}
set +e
( _respawn_backend_or_rollback codex pane-test "$WORKROOT/cwd" 'exec codex' "$WORKROOT/policy.json" sha256:test "$WORKROOT/manifest.json" session-test rt-test runtime-test "" ) \
  >/dev/null 2>"$WORKROOT/respawn-fail.err"
RC=$?
set -u
if [ "$RC" -eq 5 ] && [ "$(cat "$RESPAWN_ROLLBACK_MARKER" 2>/dev/null)" = $'codex\tsession-test\trt-test\truntime-test' ]; then
  pass "respawn failure rolls back the unverified generation before exit"
else
  fail "respawn failure did not rollback correctly (rc=$RC marker=$(cat "$RESPAWN_ROLLBACK_MARKER" 2>/dev/null || true))"
fi

# respawn 後の backend-ready failure は sentinel 未検証 backend を残さず rollback する。
READY_ROLLBACK_MARKER="$WORKROOT/ready-rollback"
agentctl_wait_backend_ready() { agentctl_die --code 5 "forced backend-ready failure"; }
_rollback_failed_guard_generation() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$READY_ROLLBACK_MARKER"
  return 0
}
set +e
( _wait_backend_ready_or_rollback codex pane-test "$WORKROOT/runtime" session-test rt-test runtime-test "" ) \
  >/dev/null 2>"$WORKROOT/ready-fail.err"
RC=$?
set -u
if [ "$RC" -eq 5 ] && [ "$(cat "$READY_ROLLBACK_MARKER" 2>/dev/null)" = $'codex\tsession-test\trt-test\truntime-test' ]; then
  pass "backend-ready failure after respawn rolls back the unverified generation before exit"
else
  fail "backend-ready failure did not rollback correctly (rc=$RC marker=$(cat "$READY_ROLLBACK_MARKER" 2>/dev/null || true))"
fi

# Codex pending registry publish failure も respawn 済み backend を rollback する。
PENDING_ROLLBACK_MARKER="$WORKROOT/pending-rollback"
agentctl_gen_runtime_id() { printf '%s\n' 'nonce-test'; }
agentctl_codex_hook_publish_pending() { return 1; }
_rollback_failed_guard_generation() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$PENDING_ROLLBACK_MARKER"
  return 0
}
set +e
( _prepare_codex_guard_pending_or_rollback session-test rt-test runtime-test "" "$WORKROOT/runtime" "$WORKROOT/policy.json" sha256:test "$WORKROOT/cwd" ) \
  >/dev/null 2>"$WORKROOT/pending-fail.err"
RC=$?
set -u
if [ "$RC" -eq 5 ] && [ "$(cat "$PENDING_ROLLBACK_MARKER" 2>/dev/null)" = $'codex\tsession-test\trt-test\truntime-test' ]; then
  pass "Codex pending-binding failure after respawn rolls back the unverified generation"
else
  fail "Codex pending-binding failure did not rollback correctly (rc=$RC marker=$(cat "$PENDING_ROLLBACK_MARKER" 2>/dev/null || true))"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "agentctl publication rollback tests: PASS"
else
  echo "agentctl publication rollback tests: FAIL"
fi
exit "$FAILED"
