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
command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping dispatcher tests"; exit 0; }

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

WORKROOT=$(mktemp -d)
TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR" "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-dispatcher-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export TMUX_TMPDIR PATH="$WORKROOT/bin:$PATH"
unset TMUX || true
trap 'tmux kill-server >/dev/null 2>&1 || true; rm -rf "$WORKROOT"' EXIT

REPO="$WORKROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" -c core.hooksPath=/dev/null init -q -b main
git -C "$REPO" config user.email t@e.com
git -C "$REPO" config user.name t
git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m init
GCD=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)

POLICY_FILE="$WORKROOT/policy.snapshot.json"
jq -n --arg gcd "$GCD" '{version:1,permissions:{push:false,commit:true},scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[]}],remotes:[],production_targets:[]}}' >"$POLICY_FILE"
POLICY_DIGEST=$(jq -S -c . "$POLICY_FILE" | sha256sum | awk '{print "sha256:" $1}')

# 実 runtime を模した tmux pane と state.json を用意する (Fix #8: dispatcher は
# policy version と pane owner/runtime_id/name/backend/schema marker を
# state.json と突き合わせて検証するため)。
STATE_FILE="$WORKROOT/state.json"
jq -n '{schema_version:1,name:"rtdisp",backend:"fake",runtime_id:"rt1"}' >"$STATE_FILE"
tmux new-session -d -s disptest -c "$WORKROOT"
PANE=$(tmux display-message -p -t disptest '#{pane_id}')
tmux set-option -p -t "$PANE" @agentctl_owner agentctl
tmux set-option -p -t "$PANE" @agentctl_name rtdisp
tmux set-option -p -t "$PANE" @agentctl_runtime_id rt1
tmux set-option -p -t "$PANE" @agentctl_backend fake
tmux set-option -p -t "$PANE" @agentctl_schema_version 1
export TMUX_PANE="$PANE"

run_dispatcher() {
  local tool_input_command="$1"
  jq -n --arg cmd "$tool_input_command" '{tool_name:"Bash", tool_input:{command:$cmd}}' | bash "$DISPATCHER"
}

# --- 通常 session (env 無し) は no-op -----------------------------------------------------------

OUT=$(unset AGENTCTL_POLICY_SNAPSHOT AGENTCTL_RUNTIME_ID; run_dispatcher "git push origin")
[ -z "$OUT" ] && pass "no AGENTCTL env -> no-op (existing session behavior unchanged)" \
  || fail "expected no-op without agentctl env, got: $OUT"

# --- Codex interactive TUI: ambient AGENTCTL_* が消える場合の session binding -----------------------------
# Codex 0.154.0 interactive TUI では、TUI 起動時に渡した AGENTCTL_* が
# PreToolUse hook subprocess へ継承されない。agentctl sentinel marker の runtime_id と
# hook stdin の stable session_id を初回だけ binding し、以後は session_id から
# runtime generation / policy snapshot を解決できることを検証する。
CODEX_TEST_HOME="$WORKROOT/codex-home"
CODEX_REGISTRY="$CODEX_TEST_HOME/.local/state/agentctl/codex-hook-bindings"
CODEX_RUNTIME_DIR="$WORKROOT/codex-runtime"
CODEX_RID="codex-rt1"
CODEX_SESSION_ID="codex-session-1"
mkdir -p "$CODEX_REGISTRY/pending" "$CODEX_REGISTRY/sessions" "$CODEX_RUNTIME_DIR"
chmod 0700 "$CODEX_REGISTRY" "$CODEX_REGISTRY/pending" "$CODEX_REGISTRY/sessions"
CODEX_POLICY="$CODEX_RUNTIME_DIR/policy.snapshot.json"
cp "$POLICY_FILE" "$CODEX_POLICY"
CODEX_POLICY_DIGEST=$(jq -S -c . "$CODEX_POLICY" | sha256sum | awk '{print "sha256:" $1}')
jq -n --arg cwd "$REPO" --arg rid "$CODEX_RID" \
  '{schema_version:1,name:"codexdisp",backend:"codex",runtime_id:$rid,cwd:$cwd,status:"starting"}' \
  >"$CODEX_RUNTIME_DIR/state.json"
RID_KEY=$(printf '%s' "$CODEX_RID" | sha256sum | awk '{print $1}')
SESSION_KEY=$(printf '%s' "$CODEX_SESSION_ID" | sha256sum | awk '{print $1}')
jq -n --arg rid "$CODEX_RID" --arg runtime_dir "$CODEX_RUNTIME_DIR" \
  --arg policy "$CODEX_POLICY" --arg digest "$CODEX_POLICY_DIGEST" --arg cwd "$REPO" \
  '{schema_version:1,runtime_id:$rid,name:"codexdisp",backend:"codex",runtime_dir:$runtime_dir,policy_snapshot:$policy,policy_digest:$digest,cwd:$cwd}' \
  >"$CODEX_REGISTRY/pending/$RID_KEY.json"
chmod 0600 "$CODEX_REGISTRY/pending/$RID_KEY.json"

CODEX_SENTINEL_TOOL_INPUT="const r = await tools.exec_command({\"cmd\":\"true '#agentctl-guard-sentinel:$CODEX_RID'\"});"
CODEX_SENTINEL_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg ti "$CODEX_SENTINEL_TOOL_INPUT" \
  '{session_id:$sid,cwd:$cwd,tool_name:"exec",tool_input:$ti}')
OUT=$(printf '%s\n' "$CODEX_SENTINEL_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
EV_DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty')
[ "$EV_DECISION" = "deny" ] \
  && [ -f "$CODEX_RUNTIME_DIR/guard-sentinel.json" ] \
  && [ -f "$CODEX_REGISTRY/sessions/$SESSION_KEY.json" ] \
  && [ ! -f "$CODEX_REGISTRY/pending/$RID_KEY.json" ] \
  && pass "Codex sentinel without ambient AGENTCTL_* binds hook session_id to the exact runtime generation and records deny evidence" \
  || fail "expected Codex sentinel session binding + deny evidence without ambient env, got: $OUT"

CODEX_PUSH_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:"git push origin"}}')
OUT=$(printf '%s\n' "$CODEX_PUSH_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "bound Codex session resolves policy without ambient AGENTCTL_* and denies disallowed privileged operation" \
  || fail "expected bound Codex session policy deny, got: $OUT"

CODEX_LS_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls -la"}}')
OUT=$(printf '%s\n' "$CODEX_LS_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] && pass "bound Codex session allows non-privileged operation without ambient AGENTCTL_*" \
  || fail "expected bound Codex session non-privileged no-op, got: $OUT"

# real Codex 0.154.0 が operation file bootstrap を読む際に実測した exact shape。
# generic classifier の quote fail-closed は維持したまま、この runtime 自身の
# codex-op-*.txt に対する read-only verification/read sequence だけを許可する。
CODEX_OP="$CODEX_RUNTIME_DIR/codex-op-11111111-2222-3333-4444-555555555555.txt"
printf 'bootstrap body\n' >"$CODEX_OP"
chmod 0600 "$CODEX_OP"
CODEX_OP_CMD="sha256sum $CODEX_OP && wc -c $CODEX_OP && sed -n '1,240p' $CODEX_OP"
CODEX_OP_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] \
  && pass "bound Codex session allows the exact read-only operation-file bootstrap command for its own runtime" \
  || fail "expected exact Codex operation-file read bootstrap to pass, got: $OUT"

# Codex は file size/context に応じて sed の上限行数を変える (実機で 240/260 を観測)。
# 行数だけは正の整数として可変にし、他の command shape/path は exact に固定する。
CODEX_OP_CMD_260="sha256sum $CODEX_OP && wc -c $CODEX_OP && sed -n '1,260p' $CODEX_OP"
CODEX_OP_PAYLOAD_260=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_CMD_260" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_PAYLOAD_260" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] \
  && pass "bound Codex session allows a different positive sed line limit for the exact operation-file bootstrap" \
  || fail "expected operation-file read bootstrap with sed 260 to pass, got: $OUT"

CODEX_OP_HASH_SIZE_CMD="sha256sum $CODEX_OP && wc -c $CODEX_OP"
CODEX_OP_HASH_SIZE_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_HASH_SIZE_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_HASH_SIZE_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] \
  && pass "bound Codex session allows exact hash+size verification for its own operation file" \
  || fail "expected operation-file hash+size verification to pass, got: $OUT"

CODEX_OP_SED_CMD="sed -n '1,9999p' $CODEX_OP"
CODEX_OP_SED_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_SED_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_SED_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] \
  && pass "bound Codex session allows exact positive-range sed read for its own operation file" \
  || fail "expected operation-file sed read to pass, got: $OUT"

# real Codex queue turn で実測した分割 read shape: hash 単体 + EOF までの sed。
CODEX_OP_HASH_CMD="sha256sum $CODEX_OP"
CODEX_OP_HASH_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_HASH_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_HASH_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] \
  && pass "bound Codex session allows exact sha256sum read for its own operation file" \
  || fail "expected operation-file sha256sum read to pass, got: $OUT"

CODEX_OP_SED_EOF_CMD="sed -n '1,\$p' $CODEX_OP"
CODEX_OP_SED_EOF_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_SED_EOF_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_SED_EOF_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
[ -z "$OUT" ] \
  && pass "bound Codex session allows exact sed read through EOF for its own operation file" \
  || fail "expected operation-file sed EOF read to pass, got: $OUT"


# Raw, unquoted operation-file paths must never be accepted when the runtime path contains
# shell metacharacters. Otherwise the exact allow exception itself can bless a command whose
# operand triggers shell expansion/control syntax. The shell-escaped variant remains safe.
META_RUNTIME="$WORKROOT/codex-runtime;\$(id)"
mkdir -p "$META_RUNTIME"
META_POLICY="$META_RUNTIME/policy.snapshot.json"
cp "$POLICY_FILE" "$META_POLICY"
META_OP="$META_RUNTIME/codex-op-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.txt"
printf 'meta\n' >"$META_OP"
META_RAW_CMD="sed -n '1,1p' $META_OP"
META_ESCAPED=$(printf '%q' "$META_OP")
META_ESCAPED_CMD="sed -n '1,1p' $META_ESCAPED"
META_RAW_RESULT=$(AGENTCTL_POLICY_SNAPSHOT="$META_POLICY" bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  source '$REPO_ROOT/home/bin/agentctl-classify.sh'
  source '$DISPATCHER'
  if agentctl_policy_dispatcher_is_codex_operation_read \"\$1\"; then echo allow; else echo deny; fi
" _ "$META_RAW_CMD")
[ "$META_RAW_RESULT" = "deny" ] \
  && pass "Codex operation-file raw path with shell metacharacters is never whitelisted" \
  || fail "raw metacharacter operation-file path was whitelisted: $META_RAW_RESULT"
META_ESCAPED_RESULT=$(AGENTCTL_POLICY_SNAPSHOT="$META_POLICY" bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  source '$REPO_ROOT/home/bin/agentctl-classify.sh'
  source '$DISPATCHER'
  if agentctl_policy_dispatcher_is_codex_operation_read \"\$1\"; then echo allow; else echo deny; fi
" _ "$META_ESCAPED_CMD")
[ "$META_ESCAPED_RESULT" = "allow" ] \
  && pass "Codex operation-file shell-escaped metacharacter path remains a safe exact read" \
  || fail "escaped metacharacter operation-file path should be allowed: $META_ESCAPED_RESULT"

CODEX_OP_SED_EOF_EXTRA_CMD="$CODEX_OP_SED_EOF_CMD && git push origin"
CODEX_OP_SED_EOF_EXTRA_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_SED_EOF_EXTRA_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_SED_EOF_EXTRA_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "Codex operation-file EOF read with extra privileged command is not whitelisted -> deny" \
  || fail "expected extended operation-file EOF read to deny, got: $OUT"

CODEX_OP_BAD_SED_CMD="sed -n '0,9999p' $CODEX_OP"
CODEX_OP_BAD_SED_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$CODEX_OP_BAD_SED_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$CODEX_OP_BAD_SED_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "operation-file sed read with non-positive range -> deny" \
  || fail "expected non-positive sed range to deny, got: $OUT"

OUTSIDE_OP="$WORKROOT/codex-op-outside.txt"
printf 'outside\n' >"$OUTSIDE_OP"
OUTSIDE_CMD="sha256sum $OUTSIDE_OP && wc -c $OUTSIDE_OP && sed -n '1,240p' $OUTSIDE_OP"
OUTSIDE_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$OUTSIDE_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$OUTSIDE_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "Codex operation-file read shape targeting outside its bound runtime -> deny" \
  || fail "expected outside-runtime operation-file read to deny, got: $OUT"

EXTRA_CMD="$CODEX_OP_CMD && git push origin"
EXTRA_PAYLOAD=$(jq -n --arg sid "$CODEX_SESSION_ID" --arg cwd "$REPO" --arg cmd "$EXTRA_CMD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')
OUT=$(printf '%s\n' "$EXTRA_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "Codex operation-file read prefix with extra privileged command is not whitelisted -> deny" \
  || fail "expected extended operation-file command to deny, got: $OUT"

# 同じ session binding が残っていても state.json が後継 generation に変わったら
# stale session は必ず deny する (session_id だけを永続 trust token にしない)。
jq --arg rid "codex-rt2" '.runtime_id=$rid' "$CODEX_RUNTIME_DIR/state.json" >"$CODEX_RUNTIME_DIR/state.json.tmp"
mv "$CODEX_RUNTIME_DIR/state.json.tmp" "$CODEX_RUNTIME_DIR/state.json"
OUT=$(printf '%s\n' "$CODEX_LS_PAYLOAD" | HOME="$CODEX_TEST_HOME" \
  env -u AGENTCTL_POLICY_SNAPSHOT -u AGENTCTL_RUNTIME_ID -u AGENTCTL_POLICY_DIGEST -u TMUX_PANE \
  bash "$DISPATCHER")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "bound Codex session whose runtime generation was superseded -> deny (fail closed)" \
  || fail "expected stale Codex session binding deny, got: $OUT"
jq --arg rid "$CODEX_RID" '.runtime_id=$rid' "$CODEX_RUNTIME_DIR/state.json" >"$CODEX_RUNTIME_DIR/state.json.tmp"
mv "$CODEX_RUNTIME_DIR/state.json.tmp" "$CODEX_RUNTIME_DIR/state.json"

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

# --- 実 process env に継承された GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* override -----------------------------------------------------------
# (.tool_input.command 自体には現れない、hook process が backend プロセスから
# 継承した override) も fail closed で deny することを検証する。

OUT=$(GIT_DIR="/tmp/other/.git" AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "git -C $REPO commit -m msg")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "inherited real GIT_DIR env (absent from .tool_input.command) -> deny even for an otherwise-allowed git operation" \
  || fail "expected deny for inherited GIT_DIR env override, got: $OUT"

OUT=$(GIT_WORK_TREE="/tmp/other-worktree" AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "git -C $REPO commit -m msg")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "inherited real GIT_WORK_TREE env -> deny" || fail "expected deny for inherited GIT_WORK_TREE env override, got: $OUT"

OUT=$(GIT_CONFIG_COUNT="1" GIT_CONFIG_KEY_0="core.hooksPath" GIT_CONFIG_VALUE_0="/tmp/evil-hooks" \
  AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "git -C $REPO commit -m msg")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "inherited real GIT_CONFIG_COUNT/KEY_/VALUE_ env family -> deny" \
  || fail "expected deny for inherited GIT_CONFIG_* env override, got: $OUT"

OUT=$(FOO="bar" AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "git -C $REPO commit -m msg")
[ -z "$OUT" ] && pass "ordinary inherited env (non-Git-override) does not affect classification -> no-op" \
  || fail "expected no-op unaffected by ordinary inherited env, got: $OUT"

# --- Fix #8: schema/runtime ownership marker fail-closed hardening -----------------------------------------------------------

OUT=$(TMUX_PANE="" AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "missing TMUX_PANE (no tmux ownership evidence) -> deny (fail closed)" || fail "expected deny, got: $OUT"

BAD_SCHEMA_POLICY="$WORKROOT/policy.schema2.json"
jq '.version = 2' "$POLICY_FILE" >"$BAD_SCHEMA_POLICY"
BAD_SCHEMA_DIGEST=$(jq -S -c . "$BAD_SCHEMA_POLICY" | sha256sum | awk '{print "sha256:" $1}')
OUT=$(AGENTCTL_POLICY_SNAPSHOT="$BAD_SCHEMA_POLICY" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$BAD_SCHEMA_DIGEST" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "unsupported policy version -> deny (fail closed)" || fail "expected deny, got: $OUT"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt-superseded" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "AGENTCTL_RUNTIME_ID not matching state.json runtime_id (superseded generation) -> deny" \
  || fail "expected deny, got: $OUT"

# pane markers (name=rtdisp) と食い違う state.json を持つ別 runtime dir を使う
# ことで、他 runtime 向けの生きた pane が偶然この state.json と全 field 一致
# してしまう false negative を避け、marker/state 不一致検出を確実に踏む。
STALE_STATE_DIR="$WORKROOT/stale-state"
mkdir -p "$STALE_STATE_DIR"
jq -n '{schema_version:1,name:"other-runtime",backend:"fake",runtime_id:"rt1"}' >"$STALE_STATE_DIR/state.json"
STALE_POLICY="$STALE_STATE_DIR/policy.snapshot.json"
cp "$POLICY_FILE" "$STALE_POLICY"
OUT=$(AGENTCTL_POLICY_SNAPSHOT="$STALE_POLICY" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "tmux pane marker not matching state.json (tampered/missing marker) -> deny" \
  || fail "expected deny, got: $OUT"

tmux set-option -p -t "$PANE" @agentctl_runtime_id rt-tampered
OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "ls")
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "tmux pane runtime_id marker tampered away from state.json -> deny" \
  || fail "expected deny, got: $OUT"
tmux set-option -p -t "$PANE" @agentctl_runtime_id rt1

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" run_dispatcher "ls -la")
[ -z "$OUT" ] && pass "restored marker + valid ownership evidence -> not_privileged no-op (existing behavior unaffected)" \
  || fail "expected no-op, got: $OUT"

# --- 実測: 実 Codex model (gpt-5.6-terra) は shell command を "Bash" という
# 名前の tool ではなく、code-mode の "exec" tool 経由 (tool_input が任意形状の
# JS ソース) で実行することがある。hooks.json の matcher は "^(Bash|exec)$" で
# これも PreToolUse として捕捉するが、"exec" の tool_input からクリーンな
# command 文字列を取り出せる保証は無いため、分類不能として常に deny する
# (fail closed。取り出せないまま無条件 allow する fail-open を避ける) ------------------------------------------------------------------------

run_dispatcher_tool() {
  local tool_name="$1" tool_input_json="$2"
  jq -n --arg tn "$tool_name" --argjson ti "$tool_input_json" '{tool_name:$tn, tool_input:$ti}' | bash "$DISPATCHER"
}

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" \
  run_dispatcher_tool "exec" '"const r = await tools.exec_command({\"cmd\": \"ls -la\"});"')
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "non-Bash tool_name (exec, code-mode) with unparseable command text -> deny by default (fail closed)" \
  || fail "expected deny for unclassifiable non-Bash tool call, got: $OUT"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" \
  run_dispatcher_tool "exec" "\"const r = await tools.exec_command({\\\"cmd\\\": \\\"true '#agentctl-guard-sentinel:rt1'\\\"});\"")
EV_DECISION=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty')
[ "$EV_DECISION" = "deny" ] && [ -f "$WORKROOT/guard-sentinel.json" ] \
  && pass "guard sentinel probe embedded in a non-Bash (exec) tool call still writes evidence and denies" \
  || fail "expected sentinel evidence + deny for exec-tool sentinel probe, got: $OUT"
rm -f "$WORKROOT/guard-sentinel.json"

OUT=$(AGENTCTL_POLICY_SNAPSHOT="$POLICY_FILE" AGENTCTL_RUNTIME_ID="rt1" AGENTCTL_POLICY_DIGEST="$POLICY_DIGEST" \
  run_dispatcher_tool "Read" '{"file_path":"/etc/hostname"}')
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && pass "another non-Bash tool_name (Read) -> deny by default (fail closed)" \
  || fail "expected deny for non-Bash tool_name, got: $OUT"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-dispatcher unit tests passed."
else
  echo "Some agentctl-dispatcher unit tests FAILED."
fi
exit "$FAILED"
