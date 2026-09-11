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

if [ "$FAILED" -eq 0 ]; then
  echo "agentctl publication rollback tests: PASS"
else
  echo "agentctl publication rollback tests: FAIL"
fi
exit "$FAILED"
