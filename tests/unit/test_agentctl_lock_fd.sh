#!/bin/bash
# shellcheck disable=SC2015,SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/home/bin/agentctl-common.sh"
FAILED=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; FAILED=1; }

WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT
MARKER="$WORKROOT/injected"

# lock FD 値は内部数値としてのみ扱い、shell program として解釈してはならない。
AGENTCTL_LOCK_FD="9<&-; touch $MARKER; #"
set +e
agentctl_tmux display-message -p '#{session_name}' >/dev/null 2>&1
set -e
[ ! -e "$MARKER" ] && pass "malformed AGENTCTL_LOCK_FD cannot inject a command through tmux wrapper" \
  || fail "malformed AGENTCTL_LOCK_FD executed injected shell code"

AGENTCTL_DEPLOY_LOCK_FD="9<&-; touch $MARKER; #"
set +e
agentctl_release_deployment_lock >/dev/null 2>&1
set -e
[ ! -e "$MARKER" ] && pass "malformed deployment lock FD cannot inject a command through release" \
  || fail "malformed AGENTCTL_DEPLOY_LOCK_FD executed injected shell code"

if [ "$FAILED" -eq 0 ]; then
  echo "agentctl lock-fd tests: PASS"
  exit 0
fi
echo "agentctl lock-fd tests: FAIL"
exit 1
