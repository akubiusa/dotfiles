#!/bin/bash
# shellcheck disable=SC2015
# SC2015: `check && pass || fail` は本テストの意図通り。
# agentctl-policy-dispatcher.sh の PreToolUse hook 契約テスト。
# 実 Codex/Claude PreToolUse invocation による検証 (harmless sentinel 等) は
# 対象外 (Task 11 の live E2E 依存分)。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DISPATCHER="$REPO_ROOT/home/bin/agentctl-policy-dispatcher.sh"

command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping dispatcher tests"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "⚠️  git not found; skipping dispatcher tests"; exit 0; }

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT

REPO="$WORKROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" -c core.hooksPath=/dev/null init -q -b main
git -C "$REPO" config user.email t@e.com
git -C "$REPO" config user.name t
git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m init
GCD=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)

POLICY_FILE="$WORKROOT/policy.snapshot.json"
jq -n --arg gcd "$GCD" '{permissions:{push:false,commit:true},repository:{git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[]},remotes:[]}' >"$POLICY_FILE"
POLICY_DIGEST=$(jq -S -c . "$POLICY_FILE" | sha256sum | awk '{print "sha256:" $1}')

run_dispatcher() {
  local tool_input_command="$1"
  jq -n --arg cmd "$tool_input_command" '{tool_name:"Bash", tool_input:{command:$cmd}}' | bash "$DISPATCHER"
}

# --- 通常 session (env 無し) は no-op -----------------------------------------------------------

OUT=$(unset AGENTCTL_POLICY_SNAPSHOT AGENTCTL_RUNTIME_ID; run_dispatcher "git push origin")
[ -z "$OUT" ] && pass "no AGENTCTL env -> no-op (existing session behavior unchanged)" \
  || fail "expected no-op without agentctl env, got: $OUT"

# --- agentctl runtime: dependency/snapshot 欠落は fail closed -----------------------------------------------------------

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "missing AGENTCTL_RUNTIME_ID -> deny (fail closed)" || fail "expected deny, got: $OUT"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$WORKROOT/does-not-exist.json" AGENTCTL_RUNTIME_ID="rt1" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "missing policy snapshot file -> deny (fail closed)" || fail "expected deny, got: $OUT"

BAD_SNAPSHOT="$WORKROOT/bad.json"
echo 'not json' >"$BAD_SNAPSHOT"
OUT=$(AGENTCTL_POLICY_SNAPSHOT="$BAD_SNAPSHOT" AGENTCTL_RUNTIME_ID="rt1" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "invalid JSON policy snapshot -> deny (fail closed)" || fail "expected deny, got: $OUT"

FAKE_BIN="$WORKROOT/fakebin"
mkdir -p "$FAKE_BIN"
BASH_BIN=$(command -v bash)
PAYLOAD=$(jq -n --arg cmd "ls" '{tool_name:"Bash", tool_input:{command:$cmd}}')
# PATH を空 dir だけにして jq 不在を再現しつつ、bash 実行ファイル自体は絶対 path で呼ぶ
# (PATH 制限が「bash を探す」段階に影響しないようにする)。
OUT=$(echo "$PAYLOAD" | PATH="$FAKE_BIN" AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" "$BASH_BIN" "$DISPATCHER" 2>/dev/null)
echo "$OUT" | grep -q '"permissionDecision":"deny"' \
  && pass "missing jq dependency -> deny (fail closed, no jq needed to emit it)" || fail "expected deny, got: $OUT"

# --- agentctl runtime: policy digest fail-closed -----------------------------------------------------------

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "missing AGENTCTL_POLICY_DIGEST -> deny (fail closed)" || fail "expected deny, got: $OUT"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "AGENTCTL_POLICY_DIGEST mismatch -> deny (snapshot tampered/stale)" || fail "expected deny, got: $OUT"

# --- agentctl runtime: 実 classification -----------------------------------------------------------

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "git push origin")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "privileged denied command -> deny" || fail "expected deny, got: $OUT"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "git -C $REPO commit -m msg")
[ -z "$OUT" ] && pass "allowed privileged command -> no-op (implicit allow)" \
  || fail "expected no-op for allowed command, got: $OUT"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "ls -la")
[ -z "$OUT" ] && pass "not_privileged command -> no-op" \
  || fail "expected no-op for not_privileged command, got: $OUT"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-dispatcher unit tests passed."
else
  echo "Some agentctl-dispatcher unit tests FAILED."
fi
exit "$FAILED"
