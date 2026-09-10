#!/bin/bash
# shellcheck disable=SC2015,SC2016
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2016: CLAUDE_CONFIG_DIR fixture は意図的な literal string (展開させない)。
# agentctl-backend-claude.sh / agentctl-backend-codex.sh の command 構築と
# preflight fail-closed 挙動のテスト。実 claude/codex CLI 起動 (Task 13 live
# E2E) は対象外。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091
source "$REPO_ROOT/home/bin/agentctl-common.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/home/bin/agentctl-backend-claude.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/home/bin/agentctl-backend-codex.sh"

command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping backend tests"; exit 0; }

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT

DIR="$WORKROOT/runtime"
mkdir -p "$DIR"
POLICY_SNAPSHOT="$WORKROOT/policy.snapshot.json"
echo '{"permissions":{"local_write":true}}' >"$POLICY_SNAPSHOT"
POLICY_SNAPSHOT_RO="$WORKROOT/policy.snapshot.readonly.json"
echo '{"permissions":{"local_write":false}}' >"$POLICY_SNAPSHOT_RO"

# --- claude backend -----------------------------------------------------------

CMD=$(agentctl_backend_claude_command "claude" "$POLICY_SNAPSHOT" "$DIR")
echo "$CMD" | grep -q '^exec claude --settings ' \
  && pass "claude command execs claude with --settings" || fail "unexpected claude command: $CMD"
echo "$CMD" | grep -q 'CLAUDE_CONFIG_DIR' \
  && fail "plain 'claude' backend must not set CLAUDE_CONFIG_DIR: $CMD" \
  || pass "plain 'claude' backend does not override CLAUDE_CONFIG_DIR"
[ -f "$DIR/claude-session-settings.json" ] && pass "claude session settings file written" \
  || fail "claude session settings file missing"
jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$DIR/claude-session-settings.json" >/dev/null 2>&1 \
  && pass "claude session settings wires Bash PreToolUse guard" \
  || fail "claude session settings missing PreToolUse Bash matcher"
[ -x "$DIR/claude-guard-dispatcher.sh" ] && pass "claude guard dispatcher wrapper is executable" \
  || fail "claude guard dispatcher wrapper not executable"

DIR2="$WORKROOT/runtime2"
mkdir -p "$DIR2"
CMD2=$(agentctl_backend_claude_command "claude-work" "$POLICY_SNAPSHOT" "$DIR2")
echo "$CMD2" | grep -q 'CLAUDE_CONFIG_DIR="\$HOME/.claude-work"' \
  && pass "claude-work backend isolates CLAUDE_CONFIG_DIR" \
  || fail "claude-work backend missing CLAUDE_CONFIG_DIR isolation: $CMD2"

echo "$CMD" | grep -q -- '--permission-mode plan' \
  && fail "local_write=true must not force Plan mode: $CMD" \
  || pass "claude command with local_write=true does not force Plan mode"

DIR_RO="$WORKROOT/runtime-ro"
mkdir -p "$DIR_RO"
CMD_RO=$(agentctl_backend_claude_command "claude" "$POLICY_SNAPSHOT_RO" "$DIR_RO")
echo "$CMD_RO" | grep -q -- '--permission-mode plan' \
  && pass "local_write=false forces claude Plan mode (mechanical read-only)" \
  || fail "expected --permission-mode plan for local_write=false: $CMD_RO"

# --- codex backend: preflight fail-closed -----------------------------------------------------------

MISSING_HOME="$WORKROOT/no-codex-home"
mkdir -p "$MISSING_HOME"
OUT=$(HOME="$MISSING_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed when hooks.json is not deployed" \
  || fail "expected non-zero exit when hooks.json missing, got rc=$RC out=$OUT"

CODEX_HOME="$WORKROOT/codex-home"
mkdir -p "$CODEX_HOME/.codex/hooks"
jq -n '{hooks:{PreToolUse:[{matcher:"^Bash$",hooks:[{type:"command",command:"bash ~/.codex/hooks/git-config-guard.sh"}]}]}}' \
  >"$CODEX_HOME/.codex/hooks.json"
OUT=$(HOME="$CODEX_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed when dispatcher not registered in hooks.json" \
  || fail "expected non-zero exit when dispatcher unregistered, got rc=$RC out=$OUT"

jq '.hooks.PreToolUse += [{matcher:"^Bash$",hooks:[{type:"command",command:"bash ~/.codex/hooks/agentctl-policy-dispatcher.sh"}]}]' \
  "$CODEX_HOME/.codex/hooks.json" >"$CODEX_HOME/.codex/hooks.json.tmp" && mv "$CODEX_HOME/.codex/hooks.json.tmp" "$CODEX_HOME/.codex/hooks.json"
OUT=$(HOME="$CODEX_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed when deployed dispatcher script file itself is absent" \
  || fail "expected non-zero exit when deployed dispatcher script missing, got rc=$RC out=$OUT"

cp "$REPO_ROOT/home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh" "$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"
OUT=$(HOME="$CODEX_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
')
RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "exec codex" ] \
  && pass "codex backend succeeds when hooks.json + matching deployed dispatcher present" \
  || fail "expected 'exec codex' when preflight satisfied, got rc=$RC out=$OUT"

OUT_RO=$(HOME="$CODEX_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT_RO"'" "'"$DIR"'"
')
[ "$OUT_RO" = "exec codex -s read-only" ] \
  && pass "local_write=false forces codex -s read-only sandbox (mechanical read-only)" \
  || fail "expected 'exec codex -s read-only' for local_write=false, got: $OUT_RO"

STALE_HOME="$WORKROOT/codex-home-stale"
mkdir -p "$STALE_HOME/.codex/hooks"
cp "$CODEX_HOME/.codex/hooks.json" "$STALE_HOME/.codex/hooks.json"
echo "# stale" >"$STALE_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"
OUT=$(HOME="$STALE_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed on deployed dispatcher checksum mismatch (stale chezmoi apply)" \
  || fail "expected non-zero exit on checksum mismatch, got rc=$RC out=$OUT"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-backend unit tests passed."
else
  echo "Some agentctl-backend unit tests FAILED."
fi
exit "$FAILED"
