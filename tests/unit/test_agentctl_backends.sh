#!/bin/bash
# shellcheck disable=SC2015,SC2016
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2016: CLAUDE_CONFIG_DIR fixture は意図的な literal string (展開させない)。
# agentctl-backend-claude.sh / agentctl-backend-codex.sh の command 構築と
# preflight fail-closed 挙動のテスト。実 claude/codex CLI 起動は live E2E で扱う。

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

# --- Codex operation artifact bounds 検証 ------------------------------------------

CODEX_LIMIT_BODY="$WORKROOT/codex-limit-body.txt"
printf 'bounded body\n' >"$CODEX_LIMIT_BODY"

CODEX_COUNT_DIR="$WORKROOT/codex-count-limit"
mkdir -p "$CODEX_COUNT_DIR"
for i in $(seq 1 64); do
  printf -v suffix '%012d' "$i"
  : >"$CODEX_COUNT_DIR/codex-op-00000000-0000-0000-0000-$suffix.txt"
done
COUNT_BEFORE=$(find "$CODEX_COUNT_DIR" -maxdepth 1 -type f -name 'codex-op-*.txt' | wc -l)
agentctl_backend_codex_prepare_operation_file "$CODEX_COUNT_DIR" "$CODEX_LIMIT_BODY" >/dev/null 2>"$WORKROOT/codex-count-limit.err"
COUNT_RC=$?
COUNT_AFTER=$(find "$CODEX_COUNT_DIR" -maxdepth 1 -type f -name 'codex-op-*.txt' | wc -l)
[ "$COUNT_RC" -ne 0 ] && [ "$COUNT_BEFORE" = "$COUNT_AFTER" ] \
  && pass "Codex operation artifact count is capped before creating another file" \
  || fail "Codex operation artifact count limit was not enforced (rc=$COUNT_RC before=$COUNT_BEFORE after=$COUNT_AFTER)"

CODEX_BYTES_DIR="$WORKROOT/codex-bytes-limit"
mkdir -p "$CODEX_BYTES_DIR"
truncate -s 67108864 "$CODEX_BYTES_DIR/codex-op-00000000-0000-0000-0000-000000000001.txt"
BYTES_BEFORE=$(find "$CODEX_BYTES_DIR" -maxdepth 1 -type f -name 'codex-op-*.txt' | wc -l)
agentctl_backend_codex_prepare_operation_file "$CODEX_BYTES_DIR" "$CODEX_LIMIT_BODY" >/dev/null 2>"$WORKROOT/codex-bytes-limit.err"
BYTES_RC=$?
BYTES_AFTER=$(find "$CODEX_BYTES_DIR" -maxdepth 1 -type f -name 'codex-op-*.txt' | wc -l)
[ "$BYTES_RC" -ne 0 ] && [ "$BYTES_BEFORE" = "$BYTES_AFTER" ] \
  && pass "Codex operation artifact total bytes are capped before creating another file" \
  || fail "Codex operation artifact byte limit was not enforced (rc=$BYTES_RC before=$BYTES_BEFORE after=$BYTES_AFTER)"

# --- claude backend 検証 -----------------------------------------------------------

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

# --- codex transport bootstrap provenance 検証 -----------------------------------------------------------

BOOTSTRAP=$(agentctl_backend_codex_bootstrap_message "/tmp/agentctl-runtime/codex-op-11111111-2222-3333-4444-555555555555.txt" "0123456789abcdef")
if echo "$BOOTSTRAP" | grep -qF "verbatim user message for this turn" \
  && echo "$BOOTSTRAP" | grep -qF "agentctl transport artifact" \
  && [[ "$BOOTSTRAP" == "agentctl transport artifact: /tmp/agentctl-runtime/codex-op-11111111-2222-3333-4444-555555555555.txt"* ]] \
  && echo "$BOOTSTRAP" | grep -qF "0123456789abcdef" \
  && [ "${#BOOTSTRAP}" -le 320 ]; then
  pass "Codex bootstrap identifies the operation file as an agentctl-owned verbatim user-message transport artifact"
else
  fail "Codex bootstrap does not clearly identify trusted transport provenance: $BOOTSTRAP"
fi

# --- codex backend: preflight fail-closed 検証 -----------------------------------------------------------

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

jq '.hooks.PreToolUse += [{matcher:"^(Bash|exec)$",hooks:[{type:"command",command:"bash ~/.codex/hooks/agentctl-policy-dispatcher.sh"}]}]' \
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

# managed registration は実 Codex shell tool path と一致する matcher を要求する。
cp "$CODEX_HOME/.codex/hooks.json" "$CODEX_HOME/.codex/hooks.json.good"
jq '(.hooks.PreToolUse[] | select(any(.hooks[]?; .command == "bash ~/.codex/hooks/agentctl-policy-dispatcher.sh")) | .matcher) = "^Bash$"' \
  "$CODEX_HOME/.codex/hooks.json.good" >"$CODEX_HOME/.codex/hooks.json"
OUT=$(HOME="$CODEX_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed when the managed dispatcher matcher is stale" \
  || fail "expected non-zero exit for stale dispatcher matcher, got rc=$RC out=$OUT"
mv "$CODEX_HOME/.codex/hooks.json.good" "$CODEX_HOME/.codex/hooks.json"

# 古い wrapper が見かけ上の source line を含んでいても通さず、managed content hash で
# 配備内容そのものを検証する。
cp "$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh" "$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh.good"
printf '\n# stale-but-grep-compatible\n' >>"$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"
OUT=$(HOME="$CODEX_HOME" bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  source "'"$REPO_ROOT"'/home/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed on grep-compatible dispatcher content drift (managed checksum)" \
  || fail "grep-compatible dispatcher drift was not detected: rc=$RC out=$OUT"
mv "$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh.good" "$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"

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

# preflight は AGENTCTL_LIBDIR からの相対パスで repo checkout の source を
# 逆算しない (deployed 環境では AGENTCTL_LIBDIR=$HOME/bin であり chezmoi が
# dot_codex を .codex にリネームするため、その相対パスは存在し得ない)。
# ここでは agentctl-common.sh/agentctl-backend-codex.sh 自体を $HOME/bin へ
# コピーした simulated production layout で検証し、repo checkout の
# home/dot_codex/... へ到達できない状態でも staleness が正しく検出されることを
# 確認する。
PROD_HOME="$WORKROOT/codex-home-prod-layout"
mkdir -p "$PROD_HOME/bin" "$PROD_HOME/.codex/hooks"
cp "$REPO_ROOT/home/bin/agentctl-common.sh" "$REPO_ROOT/home/bin/agentctl-backend-codex.sh" \
  "$REPO_ROOT/home/bin/agentctl-classify.sh" "$REPO_ROOT/home/bin/agentctl-policy-dispatcher.sh" "$PROD_HOME/bin/"
cp "$REPO_ROOT/home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh" "$PROD_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"
jq -n '{hooks:{PreToolUse:[{matcher:"^(Bash|exec)$",hooks:[{type:"command",command:"bash ~/.codex/hooks/agentctl-policy-dispatcher.sh"}]}]}}' \
  >"$PROD_HOME/.codex/hooks.json"
OUT=$(HOME="$PROD_HOME" bash -c '
  source "'"$PROD_HOME"'/bin/agentctl-common.sh"
  source "'"$PROD_HOME"'/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
')
RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "exec codex" ] \
  && pass "codex backend succeeds with a correctly deployed dispatcher in a simulated production layout (AGENTCTL_LIBDIR=\$HOME/bin, no repo checkout reachable)" \
  || fail "expected 'exec codex' in simulated production layout, got rc=$RC out=$OUT"

echo "# stale" >"$PROD_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"
OUT=$(HOME="$PROD_HOME" bash -c '
  source "'"$PROD_HOME"'/bin/agentctl-common.sh"
  source "'"$PROD_HOME"'/bin/agentctl-backend-codex.sh"
  agentctl_backend_codex_command "'"$POLICY_SNAPSHOT"'" "'"$DIR"'"
' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "codex backend fails closed on a stale deployed dispatcher in a simulated production layout (previously silently passed because the repo-relative source path was unreachable)" \
  || fail "expected non-zero exit on stale dispatcher in simulated production layout, got rc=$RC out=$OUT"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-backend unit tests passed."
else
  echo "Some agentctl-backend unit tests FAILED."
fi
exit "$FAILED"
