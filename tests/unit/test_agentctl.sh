#!/bin/bash
# agentctl のユニットテスト。isolated XDG_STATE_HOME と fake backend/tmux server を使う。
# 実 Claude/Codex backend と remote/production E2E は別テストで扱う。
# shellcheck disable=SC2015,SC2329,SC2016,SC2181
# SC2015: `check && pass "..." || fail "..."` は本テストの意図通り (pass 失敗時のみ fail に落ちる想定)。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
# SC2016: stub 用の single-quoted `bash -c '...'` 内の `$i` は、外側シェルではなく
# 起動された stub 自身の bash で展開されることを意図している。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping agentctl tests"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping agentctl tests"; exit 0; }

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

# steer --stdin の temp file leak 検査を他プロセスの /tmp 活動から隔離するため専用 TMPDIR を使う。
export TMPDIR="$WORKROOT/tmp"
mkdir -p "$TMPDIR"

# 独立 tmux server (-L) を使い、ユーザの実セッションに影響しない。
# PATH 先頭に薄いラッパーを置き、agentctl 内部からの `tmux` 呼び出しも同じ server に向ける。
mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
op_index=1
if [ "\${1:-}" = "-S" ]; then
  op_index=3
fi
op="\${!op_index:-}"
if [ "\${AGENTCTL_TEST_TMUX_FAIL_LOAD_BUFFER:-0}" = "1" ] && [ "\$op" = "load-buffer" ]; then
  exit 97
fi
if [ "\${AGENTCTL_TEST_TMUX_FAIL_KILL_SESSION:-0}" = "1" ] && [ "\$op" = "kill-session" ]; then
  exit 98
fi
exec "$REAL_TMUX" -L agentctl-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"

cleanup_all() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

REPO_FIXTURE="$WORKROOT/repo"
mkdir -p "$REPO_FIXTURE/.git" "$WORKROOT/worktree"

POLICY_PERMISSIONS_ALL_FALSE='"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false}'

valid_policy() {
  cat <<JSON
{"version":1,$POLICY_PERMISSIONS_ALL_FALSE,"scope":{"repositories":[{"id":"primary","git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}],"remotes":[],"production_targets":[]}}
JSON
}

# --- keeper 自身が git/gh を呼ばないこと -----------------------------------------------------------

if grep -nE '(^|[^a-zA-Z0-9_-])(git|gh)([[:space:]]|$)' "$REPO_ROOT/home/bin/executable_agentctl" "$REPO_ROOT/home/bin/agentctl-common.sh" \
   | grep -v '^\S*:[0-9]*:#' | grep -viE 'github_repo|git_common_dir|# |agent'; then
  fail "agentctl source appears to invoke git/gh directly"
else
  pass "agentctl keeper does not call git/gh"
fi

# runtime inventory が空の doctor は空名 runtime を捏造せず、stderr も出さない。
DOCTOR_EMPTY_OUT="$WORKROOT/doctor-empty.out"
DOCTOR_EMPTY_ERR="$WORKROOT/doctor-empty.err"
if bash "$AGENTCTL" doctor --json >"$DOCTOR_EMPTY_OUT" 2>"$DOCTOR_EMPTY_ERR" \
  && jq -e '.runtimes == []' "$DOCTOR_EMPTY_OUT" >/dev/null 2>&1 \
  && [ ! -s "$DOCTOR_EMPTY_ERR" ]; then
  pass "doctor on an empty runtime inventory returns an empty array without diagnostics"
else
  fail "doctor fabricated an empty-name runtime or emitted diagnostics: out=$(cat "$DOCTOR_EMPTY_OUT" 2>/dev/null) err=$(cat "$DOCTOR_EMPTY_ERR" 2>/dev/null)"
fi

# --- policy validation 検証 -----------------------------------------------------------

# validator 関数は agentctl-common.sh 内部関数なので、必ず source した fresh shell で呼ぶ。
# 未定義 command の exit 127 を「reject」と誤認しない。
validate_policy_file() {
  bash -c 'source "$1/agentctl-common.sh"; agentctl_validate_policy_file "$2"' _ "$REPO_ROOT/home/bin" "$1"
}

POLICY_OK="$WORKROOT/policy-ok.json"
valid_policy >"$POLICY_OK"

POLICY_BAD="$WORKROOT/policy-bad.json"
echo "{\"version\":1,$POLICY_PERMISSIONS_ALL_FALSE,\"scope\":{\"repositories\":[{\"id\":\"primary\",\"git_common_dir\":\"relative/path\",\"github_repo\":\"acme/widgets\",\"allowed_worktree_roots\":[]}],\"remotes\":[],\"production_targets\":[]}}" >"$POLICY_BAD"

POLICY_DUP_REMOTE="$WORKROOT/policy-dup-remote.json"
jq --arg gcd "$REPO_FIXTURE/.git" --arg root "$WORKROOT/worktree" -n   '{version:1,permissions:{local_write:true,commit:false,push:false,create_pr:false,merge:false,git_cleanup:false,deploy:false,production_verify:false},scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[$root]}],remotes:[{repository_id:"primary",name:"origin",push_url:"git@example/a"},{repository_id:"primary",name:"origin",push_url:"git@example/b"}],production_targets:[]}}' >"$POLICY_DUP_REMOTE"
if (validate_policy_file "$POLICY_DUP_REMOTE" >/dev/null 2>&1); then
  fail "policy validator must reject duplicate (repository_id,name) remote identities"
else
  pass "policy validator rejects duplicate (repository_id,name) remote identities"
fi

POLICY_NONCANON="$WORKROOT/policy-noncanonical.json"
jq --arg gcd "$REPO_FIXTURE/../repo/.git" --arg root "$WORKROOT/worktree/../worktree" -n   '{version:1,permissions:{local_write:true,commit:false,push:false,create_pr:false,merge:false,git_cleanup:false,deploy:false,production_verify:false},scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[$root]}],remotes:[],production_targets:[]}}' >"$POLICY_NONCANON"
if (validate_policy_file "$POLICY_NONCANON" >/dev/null 2>&1); then
  fail "policy validator must reject non-canonical repository/worktree paths"
else
  pass "policy validator rejects non-canonical repository/worktree paths"
fi

# production argv[0] は PATH/cwd 解決に依存しない canonical executable identity のみ許可する。
PROD_BIN_DIR="$WORKROOT/prod-bin"
mkdir -p "$PROD_BIN_DIR"
PROD_EXE="$PROD_BIN_DIR/deploy"
printf '#!/bin/bash\nexit 0\n' >"$PROD_EXE"
chmod +x "$PROD_EXE"
PROD_LINK="$PROD_BIN_DIR/deploy-link"
ln -s "$PROD_EXE" "$PROD_LINK"
PROD_NONEXEC="$PROD_BIN_DIR/nonexec"
printf '#!/bin/bash\nexit 0\n' >"$PROD_NONEXEC"

make_prod_policy() {
  local argv0="$1" out="$2"
  jq --arg exe "$argv0" '.scope.production_targets=[{id:"pine",deploy_argv:[[$exe,"--target","pine"]],verify_argv:[]}]' "$POLICY_OK" >"$out"
}

POLICY_PROD_BARE="$WORKROOT/policy-prod-bare.json"; make_prod_policy "deploy" "$POLICY_PROD_BARE"
POLICY_PROD_REL="$WORKROOT/policy-prod-rel.json"; make_prod_policy "./prod-bin/deploy" "$POLICY_PROD_REL"
POLICY_PROD_MISSING="$WORKROOT/policy-prod-missing.json"; make_prod_policy "$PROD_BIN_DIR/missing" "$POLICY_PROD_MISSING"
POLICY_PROD_SYMLINK="$WORKROOT/policy-prod-symlink.json"; make_prod_policy "$PROD_LINK" "$POLICY_PROD_SYMLINK"
POLICY_PROD_NONEXEC="$WORKROOT/policy-prod-nonexec.json"; make_prod_policy "$PROD_NONEXEC" "$POLICY_PROD_NONEXEC"
POLICY_PROD_OK="$WORKROOT/policy-prod-ok.json"; make_prod_policy "$PROD_EXE" "$POLICY_PROD_OK"

for spec in \
  "bare:$POLICY_PROD_BARE" \
  "relative:$POLICY_PROD_REL" \
  "missing:$POLICY_PROD_MISSING" \
  "noncanonical-symlink:$POLICY_PROD_SYMLINK" \
  "non-executable:$POLICY_PROD_NONEXEC"; do
  label=${spec%%:*}; file=${spec#*:}
  if (validate_policy_file "$file" >/dev/null 2>&1); then
    fail "policy validator must reject $label production executable identity"
  else
    pass "policy validator rejects $label production executable identity"
  fi
done
if validate_policy_file "$POLICY_PROD_OK" >/dev/null 2>&1; then
  pass "policy validator accepts absolute canonical existing executable production argv[0]"
else
  fail "policy validator rejected valid canonical production executable"
fi

if bash "$AGENTCTL" start --name t1 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_BAD" --mission-stdin <<<"mission" 2>/tmp/agentctl-t1-err; then
  fail "start with invalid policy (relative path) should fail closed"
else
  BAD_POLICY_RC=$?
  grep -q "policy validation failed" /tmp/agentctl-t1-err && pass "invalid policy is rejected fail-closed" || fail "invalid policy error message missing"
  [ "$BAD_POLICY_RC" -eq 2 ] && pass "invalid/malformed policy schema exits 2 (usage/schema error, design.md:187)" \
    || fail "invalid policy schema exited $BAD_POLICY_RC, expected 2"
fi

for missing in cwd backend policy-file; do
  args=(--name t2 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK")
  case "$missing" in
    cwd) args=(--name t2 --backend fake --policy-file "$POLICY_OK") ;;
    backend) args=(--name t2 --cwd "$WORKROOT/worktree" --policy-file "$POLICY_OK") ;;
    policy-file) args=(--name t2 --cwd "$WORKROOT/worktree" --backend fake) ;;
  esac
  if bash "$AGENTCTL" start "${args[@]}" --mission-stdin <<<"m" 2>/dev/null; then
    fail "start without --$missing should be rejected"
  else
    pass "start without --$missing is rejected"
  fi
done

if bash "$AGENTCTL" start --name t3 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" 2>/dev/null; then
  fail "start without mission input should be rejected"
else
  pass "start without mission input is rejected"
fi

POLICY_RO="$WORKROOT/policy-readonly.json"
POLICY_PERMISSIONS_LOCAL_WRITE_FALSE="${POLICY_PERMISSIONS_ALL_FALSE//\"local_write\":true/\"local_write\":false}"
echo "{\"version\":1,$POLICY_PERMISSIONS_LOCAL_WRITE_FALSE,\"scope\":{\"repositories\":[{\"id\":\"primary\",\"git_common_dir\":\"$REPO_FIXTURE/.git\",\"github_repo\":\"acme/widgets\",\"allowed_worktree_roots\":[\"$WORKROOT/worktree\"]}],\"remotes\":[],\"production_targets\":[]}}" >"$POLICY_RO"
if bash "$AGENTCTL" start --name t4 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_RO" --mission-stdin <<<"m" 2>/tmp/agentctl-t4-err; then
  fail "fake backend must refuse start when local_write=false (no mechanical read-only mode)"
else
  grep -q "local_write=false" /tmp/agentctl-t4-err && pass "fake backend refuses local_write=false (no mechanical enforcement)" \
    || fail "fake backend local_write=false rejection message missing: $(cat /tmp/agentctl-t4-err)"
fi

# --- --name path traversal validation 検証 -----------------------------------------------------------
# --name はそのままディレクトリ名/tmux session 名/lock ファイル名に連結される。
# 資源化される前に allowlist ([A-Za-z0-9_-]+) 一致のみを受理し、
# traversal-like な値をすべて構造的に拒否することを、全ての public command
# (--name を取るもの) 横断で検証する。

RUNTIMES_DIR_BEFORE_TRAVERSAL=$(find "$WORKROOT/state/agentctl/runtimes" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)

if bash "$AGENTCTL" cleanup --name "" --runtime-id "00000000-0000-0000-0000-000000000000" 2>/tmp/agentctl-traversal-err; then
  fail "cleanup --name '' should be rejected"
else
  grep -q "missing required argument: --name" /tmp/agentctl-traversal-err \
    && pass "cleanup --name '' is rejected (missing required argument)" \
    || fail "cleanup --name '' rejected for the wrong reason: $(cat /tmp/agentctl-traversal-err)"
fi

for bad_name in "../victim" "/tmp/x" "a/b" "." ".." "a\\b" "$(printf 'a\tb')" "$(printf 'a\nb')" " leading-space" "trailing-space "; do
  if bash "$AGENTCTL" cleanup --name "$bad_name" --runtime-id "00000000-0000-0000-0000-000000000000" 2>/tmp/agentctl-traversal-err; then
    fail "cleanup --name '$bad_name' should be rejected (traversal-like)"
  else
    grep -q "must match \[A-Za-z0-9_-\]" /tmp/agentctl-traversal-err \
      && pass "cleanup --name '$bad_name' is rejected before path/tmux/lock construction" \
      || fail "cleanup --name '$bad_name' rejected for the wrong reason: $(cat /tmp/agentctl-traversal-err)"
  fi
done

for cmd in status logs steer attach interrupt stop resume complete; do
  extra_args=()
  case "$cmd" in
    steer) extra_args=(--runtime-id "00000000-0000-0000-0000-000000000000" --stdin) ;;
    attach|interrupt|stop|complete) extra_args=(--runtime-id "00000000-0000-0000-0000-000000000000") ;;
    resume) extra_args=(--from-runtime-id "00000000-0000-0000-0000-000000000000") ;;
  esac
  if bash "$AGENTCTL" "$cmd" --name "../escape-attempt" "${extra_args[@]}" 2>/tmp/agentctl-traversal-err <<<"" ; then
    fail "$cmd --name '../escape-attempt' should be rejected (traversal-like)"
  else
    grep -q "must match \[A-Za-z0-9_-\]" /tmp/agentctl-traversal-err \
      && pass "$cmd --name '../escape-attempt' is rejected before path/tmux/lock construction" \
      || fail "$cmd --name '../escape-attempt' rejected for the wrong reason: $(cat /tmp/agentctl-traversal-err)"
  fi
done

VICTIM_DIR="$WORKROOT/state/agentctl/runtimes/victim"
mkdir -p "$VICTIM_DIR"
echo -n marker >"$VICTIM_DIR/marker.txt"
bash "$AGENTCTL" cleanup --name "../victim" --runtime-id "00000000-0000-0000-0000-000000000000" >/dev/null 2>&1 || true
[ -f "$VICTIM_DIR/marker.txt" ] \
  && pass "cleanup --name '../victim' cannot escape the runtimes dir to remove an unrelated sibling" \
  || fail "cleanup --name '../victim' escaped the runtimes dir and removed an unrelated sibling"
rm -rf "$VICTIM_DIR"

RUNTIMES_DIR_AFTER_TRAVERSAL=$(find "$WORKROOT/state/agentctl/runtimes" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)
[ "$RUNTIMES_DIR_BEFORE_TRAVERSAL" = "$RUNTIMES_DIR_AFTER_TRAVERSAL" ] \
  && pass "traversal-like --name attempts left the runtimes dir contents unchanged" \
  || fail "runtimes dir contents changed after traversal-like --name attempts (before='$RUNTIMES_DIR_BEFORE_TRAVERSAL' after='$RUNTIMES_DIR_AFTER_TRAVERSAL')"

# --- runtime identity / locking / fencing 検証 -----------------------------------------------------------

NAME="rtA"
SINK="$WORKROOT/state/agentctl/runtimes/$NAME/fake-sink.txt"
RID=$(bash "$AGENTCTL" start --name "$NAME" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"hello mission")
if [[ "$RID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  pass "runtime_id looks like a UUID: $RID"
else
  fail "runtime_id is not a UUID: $RID"
fi

sleep 0.3

# --- task mission と同時に届ける common mission contract -----------------------------------------------------------

MISSION_DELIVERY="$WORKROOT/state/agentctl/runtimes/$NAME/mission-delivery.txt"
grep -q "AGENTCTL COMMON MISSION CONTRACT" "$MISSION_DELIVERY" \
  && pass "start delivers the common mission contract to the fake backend" \
  || fail "common mission contract missing from mission delivery bundle"
grep -q "agentctl complete" "$MISSION_DELIVERY" \
  && pass "common mission contract includes the terminal 'agentctl complete' requirement" \
  || fail "common mission contract missing the agentctl complete requirement"
if [ -f "$SINK" ]; then
  grep -q "AGENTCTL COMMON MISSION CONTRACT" "$SINK" \
    && pass "fake backend actually received the common mission contract bytes" \
    || fail "fake backend sink missing common mission contract"
fi
EXPECTED_MISSION_TAIL=$(printf '=== TASK MISSION ===\nhello mission')
ACTUAL_MISSION_TAIL=$(tail -n 2 "$MISSION_DELIVERY")
[ "$EXPECTED_MISSION_TAIL" = "$ACTUAL_MISSION_TAIL" ] \
  && pass "task mission remains byte-exact and delimited after the common contract" \
  || fail "task mission delimiter/bytes mismatch: $ACTUAL_MISSION_TAIL"
[ "$(cat "$WORKROOT/state/agentctl/runtimes/$NAME/mission.txt")" = "hello mission" ] \
  && pass "stored mission.txt stays the raw task mission (not mutated by contract composition)" \
  || fail "mission.txt was mutated by contract composition"

STATUS_JSON=$(bash "$AGENTCTL" status --name "$NAME" --json)
echo "$STATUS_JSON" | jq -e '.schema_version == 1' >/dev/null && pass "status --json has schema_version" || fail "status --json missing schema_version"
echo "$STATUS_JSON" | jq -e --arg rid "$RID" '.runtime_id == $rid' >/dev/null && pass "status --json runtime_id matches" || fail "status --json runtime_id mismatch: $STATUS_JSON"
echo "$STATUS_JSON" | jq -e '.reconcile == "running"' >/dev/null && pass "reconcile=running after start" || fail "reconcile not running: $STATUS_JSON"

STATE_FILE="$WORKROOT/state/agentctl/runtimes/$NAME/state.json"
[ "$(stat -c '%a' "$STATE_FILE")" = "600" ] && pass "state.json mode is 0600" || fail "state.json mode wrong: $(stat -c '%a' "$STATE_FILE")"
[ "$(stat -c '%a' "$WORKROOT/state/agentctl")" = "700" ] && pass "state root mode is 0700" || fail "state root mode wrong"

# marker/state runtime_id 一致
SESSION="agentctl-$NAME"
MARKER_RID=$(tmux show-options -p -t "${SESSION}" -v @agentctl_runtime_id 2>/dev/null)
[ "$MARKER_RID" = "$RID" ] && pass "tmux marker runtime_id matches state" || fail "tmux marker runtime_id mismatch: $MARKER_RID vs $RID"

# 古い runtime_id での mutation は拒否される
if bash "$AGENTCTL" steer --name "$NAME" --runtime-id "00000000-0000-0000-0000-000000000000" --stdin <<<"x" 2>/dev/null; then
  fail "steer with stale runtime_id should be rejected"
else
  pass "steer with stale runtime_id is rejected"
fi

# name-only mutation (runtime-id 必須) の拒否
if bash "$AGENTCTL" steer --name "$NAME" --stdin <<<"x" 2>/dev/null; then
  fail "steer without --runtime-id should be rejected"
else
  pass "steer without --runtime-id is rejected"
fi

# --- logs/attach/interrupt: fencing/ownership 検証 -----------------------------------------------------------

if bash "$AGENTCTL" logs 2>/dev/null; then
  fail "logs without --name should be rejected"
else
  pass "logs without --name is rejected"
fi

if bash "$AGENTCTL" logs --name "no-such-runtime-$$" 2>/dev/null; then
  fail "logs for a runtime with no owned tmux generation should be rejected"
else
  pass "logs for absent runtime is rejected (fail closed)"
fi

if bash "$AGENTCTL" attach --name "$NAME" 2>/dev/null; then
  fail "attach without --runtime-id should be rejected"
else
  pass "attach without --runtime-id is rejected"
fi

if bash "$AGENTCTL" attach --name "$NAME" --runtime-id "00000000-0000-0000-0000-000000000000" 2>/dev/null; then
  fail "attach with stale runtime-id should be rejected"
else
  pass "attach with stale runtime-id is rejected (no client connects)"
fi

if bash "$AGENTCTL" attach --name "no-such-runtime-$$" --runtime-id "$RID" 2>/dev/null; then
  fail "attach for absent runtime should be rejected"
else
  pass "attach for absent runtime is rejected"
fi

if bash "$AGENTCTL" interrupt --name "$NAME" 2>/dev/null; then
  fail "interrupt without --runtime-id should be rejected"
else
  pass "interrupt without --runtime-id is rejected"
fi

if bash "$AGENTCTL" interrupt --name "$NAME" --runtime-id "00000000-0000-0000-0000-000000000000" 2>/dev/null; then
  fail "interrupt with stale runtime-id should be rejected"
else
  pass "interrupt with stale runtime-id is rejected"
fi

if bash "$AGENTCTL" interrupt --name "no-such-runtime-$$" --runtime-id "$RID" 2>/dev/null; then
  fail "interrupt for absent runtime should be rejected"
else
  pass "interrupt for absent runtime is rejected"
fi

LOGS_OUT=$(bash "$AGENTCTL" logs --name "$NAME")
echo "$LOGS_OUT" | grep -q "hello mission" && pass "logs returns pane content including the delivered mission" \
  || fail "logs did not contain expected mission content: $LOGS_OUT"

if bash "$AGENTCTL" logs --name "$NAME" --lines notanumber 2>/dev/null; then
  fail "logs with non-numeric --lines should be rejected"
else
  pass "logs rejects non-numeric --lines"
fi

# interrupt の実送信は $NAME の pty/sink を汚す (Ctrl-C バイトが混入する) ため、
# 後続の byte-exact 転送テストと独立させて専用 runtime で検証する。
NAME_I="rtInterrupt"
RID_I=$(bash "$AGENTCTL" start --name "$NAME_I" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mi")
sleep 0.3
SINK_I="$WORKROOT/state/agentctl/runtimes/$NAME_I/fake-sink.txt"

INTERRUPT_OUT=$(bash "$AGENTCTL" interrupt --name "$NAME_I" --runtime-id "$RID_I" 2>/tmp/agentctl-interrupt-err)
[ "$INTERRUPT_OUT" = "interrupted" ] && pass "interrupt with current runtime-id succeeds" \
  || fail "interrupt failed: $(cat /tmp/agentctl-interrupt-err)"

sleep 0.3
RECONCILE_AFTER_INTERRUPT=$(bash "$AGENTCTL" status --name "$NAME_I" --json | jq -r '.reconcile')
[ "$RECONCILE_AFTER_INTERRUPT" = "running" ] && pass "interrupt (Ctrl-C keystroke) does not kill the runtime pane" \
  || fail "runtime state after interrupt is not running: $RECONCILE_AFTER_INTERRUPT"

# raw mode では Ctrl-C は OS SIGINT にならず、backend へ literal 0x03 バイトと
# して届く (real backend TUI が自前で turn interrupt として解釈する経路と同一)。
if grep -qaP '\x03' "$SINK_I" 2>/dev/null; then
  pass "interrupt delivers a literal Ctrl-C keystroke byte to the backend (not an OS kill signal)"
else
  fail "interrupt did not deliver a Ctrl-C byte to the backend sink"
fi

echo -n "post-interrupt steer" >"$WORKROOT/steer-post-interrupt.txt"
bash "$AGENTCTL" steer --name "$NAME_I" --runtime-id "$RID_I" --file "$WORKROOT/steer-post-interrupt.txt" >/dev/null
sleep 0.3
grep -q "post-interrupt steer" "$SINK_I" && pass "runtime remains steerable after interrupt" \
  || fail "steer after interrupt failed"

bash "$AGENTCTL" stop --name "$NAME_I" --runtime-id "$RID_I" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME_I" --runtime-id "$RID_I" >/dev/null

# --- submit-after-paste: real backend のみ Enter を送る -----------------------------------------------------------
# paste-buffer は実 TUI backend (Claude/Codex) の入力欄に文字を残すだけで実行
# されない。fake backend の byte-exact sink を壊さず
# 実 backend だけ submit するという分岐を、canonical mode の pane (Enter で
# 素の改行バイトが1つ届く) を使い agentctl_submit_paste を直接呼んで検証する。
# canonical mode の pane は改行が来るまで行を flush しない。fake は Enter を
# 送らないため paste した1文字 "P" は cat に一切届かず (0 byte)、実 backend
# は paste 後の settle-wait (capture-pane snapshot 静止) を経て Enter を送る
# ため "P\n" (2 byte) が届く。これにより「Enter を送ったか」と「settle-wait
# を実際に経由したか」の両方を同時に検証できる。backend ごとに独立した
# session/sink を使い、canonical mode の pending line が前 iteration から
# 漏れて混線しないようにする。
SUBMIT_DIR="$WORKROOT/submit-probe"
mkdir -p "$SUBMIT_DIR"
echo -n "P" >"$WORKROOT/submit-payload.txt"
SUBMIT_ALL_OK=1
for b in fake claude claude-work codex; do
  sess="agentctl-submit-check-$b"
  out="$WORKROOT/submit-out-$b.txt"
  tmux new-session -d -s "$sess" -- bash -c "cat >'$out'"
  sleep 0.2
  AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS=0.3 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
    source '$REPO_ROOT/home/bin/agentctl-common.sh'
    agentctl_tmux load-buffer -b submit-check -- '$WORKROOT/submit-payload.txt'
    agentctl_tmux paste-buffer -r -b submit-check -d -t '$sess'
    agentctl_submit_paste '$b' '$sess' 'P'
  "
  sleep 0.2
  tmux kill-session -t "$sess" >/dev/null 2>&1 || true
  bytes=$(wc -c <"$out")
  if [ "$b" = fake ]; then expected=0; else expected=2; fi
  if [ "$bytes" -ne "$expected" ]; then
    fail "agentctl_submit_paste for backend '$b': expected $expected bytes, got $bytes"
    SUBMIT_ALL_OK=0
  fi
done
[ "$SUBMIT_ALL_OK" -eq 1 ] \
  && pass "agentctl_submit_paste sends Enter only for real backends after post-paste settle (fake: 0 bytes buffered/unsubmitted, claude/claude-work/codex: 2 bytes each ('P\\n'))"

# Codex の steer は initial mission 実行中にも queue できる必要がある。pane 全体は
# reasoning/status 描画で変化し続けるため whole-screen quiet を待ってはいけない。
# 短い bootstrap に含まれる一意 marker が capture-pane に描画されたことだけを
# paste 完了の mechanical evidence とし、その時点で Enter を送る。
CODEX_BUSY_SESSION="agentctl-submit-codex-busy"
CODEX_BUSY_OUT="$WORKROOT/submit-codex-busy-out.txt"
CODEX_BUSY_MARKER="codex-op-11111111-2222-3333-4444-555555555555.txt"
printf '%s' "$CODEX_BUSY_MARKER" >"$WORKROOT/submit-codex-busy-payload.txt"
tmux new-session -d -s "$CODEX_BUSY_SESSION" -x 100 -y 20 -- bash -c '
  (i=0; while true; do i=$((i+1)); printf "busy-%d\n" "$i"; sleep 0.05; done) &
  noise_pid=$!
  IFS= read -r line
  printf "%s\n" "$line" >"'"$CODEX_BUSY_OUT"'"
  kill "$noise_pid" 2>/dev/null || true
  sleep 60
'
sleep 0.2
if AGENTCTL_SUBMIT_SETTLE_TIMEOUT_SECONDS=2 AGENTCTL_READY_POLL_SECONDS=0.05 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_tmux load-buffer -b codex-busy-submit -- '$WORKROOT/submit-codex-busy-payload.txt'
  agentctl_tmux paste-buffer -r -b codex-busy-submit -d -t '$CODEX_BUSY_SESSION'
  agentctl_submit_paste codex '$CODEX_BUSY_SESSION' '$CODEX_BUSY_MARKER'
" 2>/tmp/agentctl-codex-busy-submit-err; then
  for _ in $(seq 1 20); do
    [ -f "$CODEX_BUSY_OUT" ] && break
    sleep 0.05
  done
  [ "$(cat "$CODEX_BUSY_OUT" 2>/dev/null)" = "$CODEX_BUSY_MARKER" ] \
    && pass "Codex submit uses pasted bootstrap marker evidence and sends Enter even while the rest of the pane is changing" \
    || fail "Codex busy submit returned success but the queued line was not submitted"
else
  fail "Codex busy submit should not require whole-screen quiet: $(cat /tmp/agentctl-codex-busy-submit-err)"
fi
tmux kill-session -t "$CODEX_BUSY_SESSION" >/dev/null 2>&1 || true

# --- backend readiness barrier: bracketed-paste + screen quiescence, fail-closed timeout 検証 -----------------------------------------------------------
# 実 CLI 文字列には依存させず、bracketed paste 有効化シーケンス (\e[?2004h)
# の出現検出 (pipe-pane raw stream) + capture-pane スクリーン静止の両方を
# stub pane で再現して検証する。

READY_SESSION="agentctl-ready-check"

# 成功経路: 起動直後は出力し続け、少し遅れて bracketed paste を有効化して静止する
# stub。agentctl_wait_backend_ready がそれを待って正常終了することを検証する。
tmux new-session -d -s "$READY_SESSION" -- bash -c '
  for i in 1 2 3 4; do printf "booting...\n"; sleep 0.1; done
  while true; do printf "\x1b[?2004h"; sleep 0.1; done
'
READY_DIR="$WORKROOT/ready-probe-ok"
mkdir -p "$READY_DIR"
if AGENTCTL_READY_TIMEOUT_SECONDS=5 AGENTCTL_READY_SETTLE_TIMEOUT_SECONDS=5 AGENTCTL_READY_QUIET_SECONDS=0.5 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_wait_backend_ready claude '$READY_SESSION' '$READY_DIR'
"; then
  pass "agentctl_wait_backend_ready succeeds once bracketed paste is armed and screen settles"
else
  fail "agentctl_wait_backend_ready unexpectedly failed on a backend that becomes ready"
fi
tmux kill-session -t "$READY_SESSION" >/dev/null 2>&1 || true

# fail-closed 経路 (armed 判定): bracketed paste を一切送らない stub に対しては
# 短い timeout 内に die すること (無限待機しないこと) を検証する。
READY_SESSION2="agentctl-ready-check-timeout"
tmux new-session -d -s "$READY_SESSION2" -- bash -c 'sleep 3600'
READY_DIR2="$WORKROOT/ready-probe-timeout"
mkdir -p "$READY_DIR2"
if AGENTCTL_READY_TIMEOUT_SECONDS=1 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_wait_backend_ready claude '$READY_SESSION2' '$READY_DIR2'
" 2>/tmp/agentctl-ready-timeout-err; then
  fail "agentctl_wait_backend_ready should fail closed when backend never signals readiness"
else
  grep -q "did not become ready" /tmp/agentctl-ready-timeout-err \
    && pass "agentctl_wait_backend_ready fails closed (dies) within bounded timeout when backend never becomes ready" \
    || fail "agentctl_wait_backend_ready failed but without the expected fail-closed message: $(cat /tmp/agentctl-ready-timeout-err)"
fi
tmux kill-session -t "$READY_SESSION2" >/dev/null 2>&1 || true

# fail-closed 経路 (settle 判定): armed 後もスクリーンが変わり続ける stub に
# 対しては、短い settle timeout 内に die すること (無限待機しないこと) を検証する。
READY_SESSION3="agentctl-ready-check-neverquiet"
tmux new-session -d -s "$READY_SESSION3" -x 80 -y 20 -- bash -c '
  i=0
  while true; do i=$((i+1)); printf "\x1b[?2004h"; printf "line-%d\n" "$i"; sleep 0.05; done
'
READY_DIR3="$WORKROOT/ready-probe-neverquiet"
mkdir -p "$READY_DIR3"
if AGENTCTL_READY_TIMEOUT_SECONDS=5 AGENTCTL_READY_SETTLE_TIMEOUT_SECONDS=1 AGENTCTL_READY_QUIET_SECONDS=2 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_wait_backend_ready claude '$READY_SESSION3' '$READY_DIR3'
" 2>/tmp/agentctl-ready-neverquiet-err; then
  fail "agentctl_wait_backend_ready should fail closed when screen never settles after becoming ready"
else
  grep -q "screen did not settle" /tmp/agentctl-ready-neverquiet-err \
    && pass "agentctl_wait_backend_ready fails closed (dies) when screen keeps changing after becoming ready" \
    || fail "agentctl_wait_backend_ready failed but without the expected fail-closed message: $(cat /tmp/agentctl-ready-neverquiet-err)"
fi
tmux kill-session -t "$READY_SESSION3" >/dev/null 2>&1 || true

# submit 側の post-paste settle も同じ fail-closed 契約を持つこと (スクリーンが
# 変わり続ける pane に対しては無限待機せず timeout で die する)。capture-pane
# ベースの静止判定を使うため (pipe-pane raw stream 経由ではない)、独立検証で
# 指摘された「raw file size の短い静止判定は誤検知しうる」問題の対象外である
# ことを、実際に変化し続ける画面に対して確認する。
SETTLE_SESSION="agentctl-settle-timeout"
tmux new-session -d -s "$SETTLE_SESSION" -x 80 -y 20 -- bash -c '
  i=0
  while true; do i=$((i+1)); printf "line-%d\n" "$i"; sleep 0.05; done
'
if AGENTCTL_SUBMIT_SETTLE_TIMEOUT_SECONDS=1 AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS=2 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_submit_paste claude '$SETTLE_SESSION'
" 2>/tmp/agentctl-settle-timeout-err; then
  fail "agentctl_submit_paste should fail closed when pane screen never settles after paste"
else
  grep -q "did not settle" /tmp/agentctl-settle-timeout-err \
    && pass "agentctl_submit_paste fails closed (dies) when screen keeps changing after paste (capture-pane based, not fooled by pipe-pane batching)" \
    || fail "agentctl_submit_paste failed but without the expected fail-closed message: $(cat /tmp/agentctl-settle-timeout-err)"
fi
tmux kill-session -t "$SETTLE_SESSION" >/dev/null 2>&1 || true

# --- agentctl_deliver_body timeout path: failed/unknown event, fail-closed die preserved 検証 -----------------------------------------------------------
# agentctl_submit_paste の die (screen-settle timeout) はサブシェル経由で
# agentctl_deliver_body に捕捉され、events.jsonl に submission=failed/
# acceptance=unknown を1行だけ記録してから同じメッセージで die し直す
# (自動再送しない) こと、および real backend の paste/submit 挙動自体は
# サブシェル化しても変わらないこと (die メッセージが保存される) を検証する。
DELIVER_TIMEOUT_DIR="$WORKROOT/deliver-timeout"
mkdir -p "$DELIVER_TIMEOUT_DIR"
DELIVER_TIMEOUT_BODY="$WORKROOT/deliver-timeout-body.txt"
echo -n "body" >"$DELIVER_TIMEOUT_BODY"
DELIVER_TIMEOUT_SESS="agentctl-deliver-timeout"
tmux new-session -d -s "$DELIVER_TIMEOUT_SESS" -x 80 -y 20 -- bash -c '
  i=0
  while true; do i=$((i+1)); printf "line-%d\n" "$i"; sleep 0.05; done
'
if AGENTCTL_SUBMIT_SETTLE_TIMEOUT_SECONDS=1 AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS=2 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_deliver_body claude '$DELIVER_TIMEOUT_SESS' '$DELIVER_TIMEOUT_DIR' '$DELIVER_TIMEOUT_BODY' test-runtime-timeout test-op-timeout
" 2>/tmp/agentctl-deliver-timeout-err; then
  fail "agentctl_deliver_body should fail closed when screen never settles after paste"
else
  grep -q "did not settle" /tmp/agentctl-deliver-timeout-err \
    && pass "agentctl_deliver_body preserves agentctl_submit_paste's fail-closed die message on timeout" \
    || fail "agentctl_deliver_body failed but without the expected fail-closed message: $(cat /tmp/agentctl-deliver-timeout-err)"
fi
tmux kill-session -t "$DELIVER_TIMEOUT_SESS" >/dev/null 2>&1 || true

# --- A2: known pre-delivery transport failure must be typed exit 5 検証 -------------------------------
# load-buffer failure は paste-buffer より前なので backend へ byte は届いていない。
# delivery 後の acceptance=unknown ではなく、確定した transport failure として扱う。
PREFAIL_DIR="$WORKROOT/deliver-prefail"
mkdir -p "$PREFAIL_DIR"
PREFAIL_BODY="$WORKROOT/deliver-prefail-body.txt"
printf 'prefail-body' >"$PREFAIL_BODY"
bash -c '
  source "'"$REPO_ROOT"'/home/bin/agentctl-common.sh"
  agentctl_tmux() {
    if [ "${1:-}" = "load-buffer" ]; then
      return 1
    fi
    return 0
  }
  agentctl_deliver_body fake fake-pane "'"$PREFAIL_DIR"'" "'"$PREFAIL_BODY"'" pre-runtime pre-operation
' >/tmp/agentctl-deliver-prefail-out 2>/tmp/agentctl-deliver-prefail-err
PREFAIL_RC=$?
[ "$PREFAIL_RC" -eq 5 ] \
  && pass "agentctl_deliver_body returns 5 for a definite pre-delivery transport failure" \
  || fail "pre-delivery transport failure returned $PREFAIL_RC, expected 5"

# --- steer --json machine-readable result contract 検証 -----------------------------------------------------------
# result は accepted|submitted|unknown のいずれかで、本文/payload を一切含まない。
# 成功 (paste+Enter 送信確認済み) は "submitted"、screen-settle timeout で
# acceptance が不確定な場合は generic な失敗ではなく明示的に "unknown" とする。

NAME_JSON="rtSteerJson"
RID_JSON=$(bash "$AGENTCTL" start --name "$NAME_JSON" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mjson")
sleep 0.3
STEER_JSON=$(bash "$AGENTCTL" steer --name "$NAME_JSON" --runtime-id "$RID_JSON" --json --stdin <<<"steer json contract check")
echo "$STEER_JSON" | jq -e --arg rid "$RID_JSON" \
  '.result == "submitted" and .runtime_id == $rid and .transport == "fake-sink" and (.operation_id | length) > 0 and (keys | length) == 4' \
  >/dev/null 2>&1 \
  && pass "steer --json returns machine-readable result contract (result/operation_id/runtime_id/transport, no payload)" \
  || fail "steer --json contract mismatch: $STEER_JSON"

AGENTCTL_TEST_TMUX_FAIL_LOAD_BUFFER=1 \
  bash "$AGENTCTL" steer --name "$NAME_JSON" --runtime-id "$RID_JSON" --json --stdin <<<"known pre-delivery failure" \
  >/tmp/agentctl-steer-prefail-out 2>/tmp/agentctl-steer-prefail-err
STEER_PREFAIL_RC=$?
[ "$STEER_PREFAIL_RC" -eq 5 ] \
  && pass "steer exits 5 on a definite pre-delivery transport failure" \
  || fail "steer pre-delivery failure exited $STEER_PREFAIL_RC, expected 5"
tmux kill-session -t "agentctl-$NAME_JSON" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_JSON"

# backend=fake で起動した実 runtime の pane を、markers/state はそのままに
# 「一切静止しない画面」の loop へ respawn し、state.backend だけ claude に
# 差し替える (agentctl_submit_paste は backend=fake のみ即 return するため)。
NAME4_JSON="rtSteerJsonTimeout"
RID4_JSON=$(bash "$AGENTCTL" start --name "$NAME4_JSON" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m4json")
sleep 0.3
SESSION4_JSON="agentctl-$NAME4_JSON"
tmux respawn-pane -k -t "$SESSION4_JSON" -- bash -c '
  i=0
  while true; do i=$((i+1)); printf "line-%d\n" "$i"; sleep 0.05; done
'
sleep 0.2
STATE4_JSON="$WORKROOT/state/agentctl/runtimes/$NAME4_JSON/state.json"
NEW_PANE_PID=$(tmux display-message -p -t "$SESSION4_JSON" '#{pane_pid}')
NEW_PANE_ID=$(tmux display-message -p -t "$SESSION4_JSON" '#{pane_id}')
NEW_PANE_START=$(bash -c "source '$REPO_ROOT/home/bin/agentctl-common.sh'; agentctl_pid_start_token '$NEW_PANE_PID'")
jq --arg backend claude --arg pane_id "$NEW_PANE_ID" --argjson pane_pid "$NEW_PANE_PID" --arg pane_pid_start "$NEW_PANE_START" \
  '.backend = $backend | .pane_id = $pane_id | .pane_pid = $pane_pid | .pane_pid_start = $pane_pid_start' \
  "$STATE4_JSON" >"$STATE4_JSON.tmp" && mv "$STATE4_JSON.tmp" "$STATE4_JSON"

# delivery 後の unknown は再送を誘発しない non-destructive
# success として exit 0 のまま扱う (delivery 前の確定 failure だけ non-zero)。
if AGENTCTL_SUBMIT_SETTLE_TIMEOUT_SECONDS=1 AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS=2 AGENTCTL_READY_POLL_SECONDS=0.1 \
  bash "$AGENTCTL" steer --name "$NAME4_JSON" --runtime-id "$RID4_JSON" --json --stdin <<<"steer during timeout" \
  >/tmp/agentctl-steer-json-unknown-out 2>/tmp/agentctl-steer-json-unknown-err; then
  jq -e '.result == "unknown" and (.operation_id | length) > 0' /tmp/agentctl-steer-json-unknown-out >/dev/null 2>&1 \
    && pass "steer --json represents a screen-settle timeout as result=unknown/exit 0 (non-destructive success, not a generic failure)" \
    || fail "steer --json timeout output unexpected: $(cat /tmp/agentctl-steer-json-unknown-out), stderr: $(cat /tmp/agentctl-steer-json-unknown-err)"
else
  fail "steer --json should exit 0 on a post-delivery screen-settle timeout (acceptance=unknown is non-destructive success per design.md:189)"
fi
tmux kill-session -t "$SESSION4_JSON" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME4_JSON"

EVENTS_TIMEOUT_FILE="$DELIVER_TIMEOUT_DIR/events.jsonl"
if [ -f "$EVENTS_TIMEOUT_FILE" ]; then
  LINE_COUNT=$(wc -l <"$EVENTS_TIMEOUT_FILE")
  [ "$LINE_COUNT" -eq 1 ] && pass "agentctl_deliver_body timeout writes exactly one event (no auto-resend)" \
    || fail "agentctl_deliver_body timeout wrote $LINE_COUNT events, expected exactly 1"
  jq -e '.result.submission == "failed" and .result.acceptance == "unknown"' "$EVENTS_TIMEOUT_FILE" >/dev/null \
    && pass "agentctl_deliver_body timeout records submission=failed/acceptance=unknown" \
    || fail "agentctl_deliver_body timeout event fields unexpected: $(cat "$EVENTS_TIMEOUT_FILE")"
else
  fail "agentctl_deliver_body timeout did not write an events.jsonl entry"
fi

# --- arbitrary text transport 検証 -----------------------------------------------------------

PAYLOAD_JA=$(python3 -c "print('こんにちは、これはテストです。'*70, end='')")
echo -n "$PAYLOAD_JA" >"$WORKROOT/payload-ja.txt"
SPECIAL_PAYLOAD=$'line1 with "quotes" and `backticks`\nline2 $(cmd) ; -leadingdash\nline3'
printf '%s' "$SPECIAL_PAYLOAD" >"$WORKROOT/payload-special.txt"

bash "$AGENTCTL" steer --name "$NAME" --runtime-id "$RID" --file "$WORKROOT/payload-ja.txt" >/dev/null
sleep 0.5
bash "$AGENTCTL" steer --name "$NAME" --runtime-id "$RID" --file "$WORKROOT/payload-special.txt" >/dev/null
sleep 0.5

if [ -f "$SINK" ]; then
  # sink は累積書き込みのため、start 時に届く initial mission delivery bundle
  # (common contract + task mission) に続けて steer payload が並ぶ
  # (先頭に mission-delivery.txt を cat して期待値を合わせる)。
  EXPECTED=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME/mission-delivery.txt" "$WORKROOT/payload-ja.txt" "$WORKROOT/payload-special.txt")
  ACTUAL=$(cat "$SINK")
  [ "$EXPECTED" = "$ACTUAL" ] && pass "steer delivers arbitrary text (Japanese/multiline/special chars) byte-exact" \
    || fail "steer payload mismatch"
else
  fail "fake backend sink not created"
fi

# tmux buffer が残らないこと
if tmux list-buffers 2>/dev/null | grep -q agentctl-steer; then
  fail "tmux steer buffer was not cleaned up"
else
  pass "tmux steer buffer does not persist"
fi

# --- concurrent steer serialization (no byte interleave) 検証 -----------------------------------------------------------

NAME2="rtB"
RID2=$(bash "$AGENTCTL" start --name "$NAME2" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m2")
sleep 0.3
SINK2="$WORKROOT/state/agentctl/runtimes/$NAME2/fake-sink.txt"
python3 -c "print('A'*4000, end='')" >"$WORKROOT/payload-A.txt"
python3 -c "print('B'*4000, end='')" >"$WORKROOT/payload-B.txt"

bash "$AGENTCTL" steer --name "$NAME2" --runtime-id "$RID2" --file "$WORKROOT/payload-A.txt" >/dev/null &
PID_A=$!
bash "$AGENTCTL" steer --name "$NAME2" --runtime-id "$RID2" --file "$WORKROOT/payload-B.txt" >/dev/null &
PID_B=$!
wait "$PID_A" "$PID_B"
sleep 0.5

if [ -f "$SINK2" ]; then
  CONTENT=$(cat "$SINK2")
  MISSION2="$WORKROOT/state/agentctl/runtimes/$NAME2/mission-delivery.txt"
  AB=$(cat "$MISSION2" "$WORKROOT/payload-A.txt" "$WORKROOT/payload-B.txt")
  BA=$(cat "$MISSION2" "$WORKROOT/payload-B.txt" "$WORKROOT/payload-A.txt")
  if [ "$CONTENT" = "$AB" ] || [ "$CONTENT" = "$BA" ]; then
    pass "concurrent steer serialized without byte interleave"
  else
    fail "concurrent steer interleaved bytes"
  fi
else
  fail "concurrent steer sink missing"
fi

bash "$AGENTCTL" stop --name "$NAME2" --runtime-id "$RID2" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME2" --runtime-id "$RID2" >/dev/null

# --- PID reuse -> conflict 検証 -----------------------------------------------------------

NAME3="rtC"
bash "$AGENTCTL" start --name "$NAME3" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m3" >/dev/null
sleep 0.3
STATE3="$WORKROOT/state/agentctl/runtimes/$NAME3/state.json"
jq '.pane_pid_start = "bogus-start-token"' "$STATE3" >"$STATE3.tmp" && mv "$STATE3.tmp" "$STATE3"
RECONCILE3=$(bash "$AGENTCTL" status --name "$NAME3" --json | jq -r '.reconcile')
[ "$RECONCILE3" = "conflict" ] && pass "PID-start mismatch is classified as conflict" || fail "expected conflict, got $RECONCILE3"
tmux kill-session -t "agentctl-$NAME3" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME3"

# --- respawned/replaced pane process -> conflict, steer refused (stale runtime_id cannot steer replacement) 検証 --------

NAME4="rtRespawn"
RID4=$(bash "$AGENTCTL" start --name "$NAME4" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m4")
sleep 0.3
SESSION4="agentctl-$NAME4"
tmux respawn-pane -k -t "$SESSION4" >/dev/null 2>&1
sleep 0.3
RECONCILE4=$(bash "$AGENTCTL" status --name "$NAME4" --json | jq -r '.reconcile')
[ "$RECONCILE4" = "conflict" ] && pass "respawned pane (markers retained, PID replaced) is classified as conflict, not running" || fail "expected conflict, got $RECONCILE4"

if bash "$AGENTCTL" steer --name "$NAME4" --runtime-id "$RID4" <<<"steer after respawn" >/dev/null 2>&1; then
  fail "steer with stale runtime_id succeeded against a respawned/replaced pane"
else
  pass "steer with stale runtime_id is refused against a respawned/replaced pane"
fi
tmux kill-session -t "$SESSION4" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME4"

# --- cleanup must refuse conflict (no auto-remediation) 検証 -----------------------------------------------------------

NAME_CONFLICT="rtConflict"
RID_CONFLICT=$(bash "$AGENTCTL" start --name "$NAME_CONFLICT" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mc")
sleep 0.3
STATE_CONFLICT="$WORKROOT/state/agentctl/runtimes/$NAME_CONFLICT/state.json"
jq '.pane_pid_start = "bogus-start-token"' "$STATE_CONFLICT" >"$STATE_CONFLICT.tmp" && mv "$STATE_CONFLICT.tmp" "$STATE_CONFLICT"
RECONCILE_CONFLICT=$(bash "$AGENTCTL" status --name "$NAME_CONFLICT" --json | jq -r '.reconcile')
if [ "$RECONCILE_CONFLICT" = "conflict" ]; then
  if bash "$AGENTCTL" cleanup --name "$NAME_CONFLICT" --runtime-id "$RID_CONFLICT" 2>/dev/null; then
    fail "cleanup must refuse to auto-remediate a conflict state"
  else
    pass "cleanup refuses conflict state (no auto-remediation)"
  fi
else
  fail "conflict fixture setup failed: reconcile=$RECONCILE_CONFLICT"
fi
tmux kill-session -t "agentctl-$NAME_CONFLICT" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_CONFLICT"

# --- incomplete publication bootstrap rollback 検証 -----------------------------------------------------------

NAME_TIMEOUT="rtTimeout"
AGENTCTL_TEST_BOOTSTRAP_TIMEOUT_SECONDS=1 AGENTCTL_TEST_FAULT_STAGE="pre_marker" \
  bash "$AGENTCTL" start --name "$NAME_TIMEOUT" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mt" >/dev/null 2>/dev/null || true
if [ ! -e "$WORKROOT/state/agentctl/runtimes/$NAME_TIMEOUT/state.json" ] \
  && ! tmux has-session -t "=agentctl-$NAME_TIMEOUT" >/dev/null 2>&1; then
  pass "recoverable pre-marker launcher failure rolls back blocked bootstrap immediately"
else
  fail "recoverable pre-marker launcher failure left blocked bootstrap/state behind"
fi
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_TIMEOUT"

# --- steer --stdin does not leak temp file on rejection path 検証 -----------------------------------------------------------

TMP_BEFORE=$(find "$TMPDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
bash "$AGENTCTL" steer --name "$NAME_TIMEOUT" --runtime-id "00000000-0000-0000-0000-000000000000" --stdin <<<"leak-check" 2>/dev/null || true
TMP_AFTER=$(find "$TMPDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$TMP_BEFORE" = "$TMP_AFTER" ] && pass "steer --stdin does not leak temp file on rejection path" \
  || fail "steer --stdin leaked a temp file on rejection path ($TMP_BEFORE -> $TMP_AFTER)"

# --- stale / exited distinction 検証 -----------------------------------------------------------

NAME4="rtD"
RID4=$(bash "$AGENTCTL" start --name "$NAME4" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m4")
PANE_PID4=$(jq -r '.pane_pid' "$WORKROOT/state/agentctl/runtimes/$NAME4/state.json")
kill -TERM "$PANE_PID4"
sleep 0.5
RECONCILE4=$(bash "$AGENTCTL" status --name "$NAME4" --json | jq -r '.reconcile')
[ "$RECONCILE4" = "exited" ] && pass "dead pane with remain-on-exit is classified as exited" || fail "expected exited, got $RECONCILE4"
AGENTCTL_TEST_TMUX_FAIL_KILL_SESSION=1 bash "$AGENTCTL" cleanup --name "$NAME4" --runtime-id "$RID4" >/dev/null 2>"$WORKROOT/cleanup-kill-fail.err"
CLEANUP_KILL_FAIL_RC=$?
if [ "$CLEANUP_KILL_FAIL_RC" -eq 5 ] \
  && [ -f "$WORKROOT/state/agentctl/runtimes/$NAME4/state.json" ] \
  && tmux has-session -t "agentctl-$NAME4" >/dev/null 2>&1; then
  pass "cleanup preserves state/session and exits 5 when owned tmux session removal fails"
else
  fail "cleanup removed evidence or returned wrong rc after tmux kill failure (rc=$CLEANUP_KILL_FAIL_RC): $(cat "$WORKROOT/cleanup-kill-fail.err")"
fi
bash "$AGENTCTL" cleanup --name "$NAME4" --runtime-id "$RID4" >/dev/null

NAME5="rtE"
RID5=$(bash "$AGENTCTL" start --name "$NAME5" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m5")
sleep 0.3
tmux kill-session -t "agentctl-$NAME5" >/dev/null 2>&1
RECONCILE5=$(bash "$AGENTCTL" status --name "$NAME5" --json | jq -r '.reconcile')
[ "$RECONCILE5" = "stale" ] && pass "state without tmux session is classified as stale" || fail "expected stale, got $RECONCILE5"
bash "$AGENTCTL" cleanup --name "$NAME5" --runtime-id "$RID5" >/dev/null

# --- fault injection: launcher crash at 4 stages -> no unowned live agent 検証 -----------------------------------------------------------

for stage in pre_tmux pre_marker post_marker_pre_release; do
  NAME_F="fault-$stage"
  SINK_F="$WORKROOT/state/agentctl/runtimes/$NAME_F/fake-sink.txt"
  AGENTCTL_TEST_FAULT_STAGE="$stage" bash "$AGENTCTL" start --name "$NAME_F" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mf" >/dev/null 2>/dev/null || true
  sleep 0.2
  if [ -f "$SINK_F" ]; then
    fail "fault stage $stage: real backend was exec'd before release token"
  else
    pass "fault stage $stage: real backend not started before release"
  fi
  if [ ! -e "$WORKROOT/state/agentctl/runtimes/$NAME_F/state.json" ]     && ! tmux has-session -t "=agentctl-$NAME_F" >/dev/null 2>&1; then
    pass "fault stage $stage: unverified publication state/session rolled back automatically"
  else
    fail "fault stage $stage left unverified state/session behind"
  fi
  tmux kill-session -t "agentctl-$NAME_F" >/dev/null 2>&1 || true
  rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_F"
done

NAME_R="fault-post_release"
AGENTCTL_TEST_FAULT_STAGE="post_release" bash "$AGENTCTL" start --name "$NAME_R" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mr" >/dev/null 2>/dev/null || true
sleep 0.3
if tmux show-options -p -t "agentctl-$NAME_R" -v @agentctl_runtime_id >/dev/null 2>&1; then
  pass "fault stage post_release: agent remains legitimately owned (marker present)"
else
  fail "fault stage post_release: owner marker missing"
fi
tmux kill-session -t "agentctl-$NAME_R" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_R"

# --- doctor 検証 -----------------------------------------------------------

DOCTOR_JSON=$(bash "$AGENTCTL" doctor --json)
echo "$DOCTOR_JSON" | jq -e --arg n "$NAME" '.runtimes | any(.name == $n)' >/dev/null \
  && pass "doctor lists active runtime" || fail "doctor missing active runtime: $DOCTOR_JSON"

# --- policy snapshot immutability 検証 -----------------------------------------------------------

SNAPSHOT_PATH=$(find "$WORKROOT/state/agentctl/runtimes/$NAME" -maxdepth 1 -name 'policy.snapshot.*.json')
SNAPSHOT_BEFORE=$(cat "$SNAPSHOT_PATH")
echo "{\"version\":1,$POLICY_PERMISSIONS_ALL_FALSE,\"scope\":{\"repositories\":[{\"id\":\"primary\",\"git_common_dir\":\"/tmp/other/.git\",\"github_repo\":\"other/other\",\"allowed_worktree_roots\":[]}],\"remotes\":[],\"production_targets\":[]}}" >"$POLICY_OK"
SNAPSHOT_AFTER=$(cat "$SNAPSHOT_PATH")
[ "$SNAPSHOT_BEFORE" = "$SNAPSHOT_AFTER" ] && pass "policy snapshot immutable after source file edit" || fail "policy snapshot changed after source edit"

bash "$AGENTCTL" stop --name "$NAME" --runtime-id "$RID" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME" --runtime-id "$RID" >/dev/null

# --- resume/complete 検証 -----------------------------------------------------------

NAME_RS="resume-t1"
RID1=$(bash "$AGENTCTL" start --name "$NAME_RS" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m1")

if bash "$AGENTCTL" resume --name "$NAME_RS" --from-runtime-id "$RID1" 2>/tmp/agentctl-resume-err; then
  fail "resume while runtime is still running should be rejected"
else
  pass "resume while still running is rejected (reconcile must be exited/stale)"
fi

tmux kill-session -t "agentctl-$NAME_RS" >/dev/null 2>&1 || true

RID2=$(bash "$AGENTCTL" resume --name "$NAME_RS" --from-runtime-id "$RID1")
[ -n "$RID2" ] && [ "$RID2" != "$RID1" ] && pass "resume publishes a new generation with a fresh runtime_id" \
  || fail "resume did not produce a new runtime_id (got '$RID2')"

# resume は前世代 manifest/policy snapshot を鵜呑みにさせるのではなく、
# read-only continuation bundle として fresh backend へ実際に届け、実 Git/PR
# 状態の revalidate を明示指示しなければならない (単に manifest を検証して
# mission.txt を再送するだけでは不十分)。continuation context と元の
# mission は同一ファイル・単一 turn として届ける (paste+screen-settle には
# turn 完了を確認する barrier が無く、2 turn に分けると実 backend 上で
# 1 turn 目実行中の steer と区別できず衝突し得るため)。
SINK_RS="$WORKROOT/state/agentctl/runtimes/$NAME_RS/fake-sink.txt"
CONT_FILE="$WORKROOT/state/agentctl/runtimes/$NAME_RS/continuation.txt"
[ -f "$CONT_FILE" ] && pass "resume writes a continuation bundle file" \
  || fail "resume did not write continuation.txt"
[ "$(cat "$SINK_RS")" = "$(cat "$CONT_FILE")" ] \
  && pass "fresh backend receives the continuation bundle as a single atomic turn (not a separate resend)" \
  || fail "continuation bundle was not delivered to fresh backend pane as a single turn"
grep -qi "re-check the actual current state of Git" "$SINK_RS" \
  && pass "continuation bundle instructs fresh agent to revalidate real Git/PR state" \
  || fail "continuation bundle is missing the Git/PR revalidation instruction"
grep -q "$WORKROOT/worktree" "$SINK_RS" \
  && pass "continuation bundle includes predecessor manifest content" \
  || fail "continuation bundle does not include predecessor manifest content"
grep -q "permissions" "$SINK_RS" \
  && pass "continuation bundle includes the effective policy snapshot" \
  || fail "continuation bundle does not include the policy snapshot"
CONT_POS=$(grep -n "CONTINUATION CONTEXT" "$SINK_RS" | head -1 | cut -d: -f1)
MISSION_POS=$(grep -n "^m1$" "$SINK_RS" | head -1 | cut -d: -f1)
[ -n "$CONT_POS" ] && [ -n "$MISSION_POS" ] && [ "$CONT_POS" -lt "$MISSION_POS" ] \
  && pass "continuation context is ordered before the embedded original mission within the bundle" \
  || fail "continuation bundle does not order context before the embedded mission"

CONTRACT_COUNT=$(grep -c "AGENTCTL COMMON MISSION CONTRACT" "$CONT_FILE")
[ "$CONTRACT_COUNT" -eq 1 ] \
  && pass "resume continuation bundle includes the common mission contract exactly once" \
  || fail "resume continuation bundle contract count wrong (got $CONTRACT_COUNT, expected 1)"
CONTRACT_POS=$(grep -n "AGENTCTL COMMON MISSION CONTRACT" "$SINK_RS" | head -1 | cut -d: -f1)
[ -n "$CONTRACT_POS" ] && [ "$CONT_POS" -lt "$CONTRACT_POS" ] && [ "$CONTRACT_POS" -lt "$MISSION_POS" ] \
  && pass "common mission contract is ordered between continuation context and the embedded original mission" \
  || fail "common mission contract is not ordered between context and mission"

# --- resume re-policy の immutability + digest linkage -----------------------------------------------------------
# resume が明示 --policy-file を渡さない場合は前世代の snapshot path/digest を
# そのまま継承し、continuation bundle には "unchanged" を記録する。
STATE_RS1=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME_RS/state.json")
DIGEST_G1=$(echo "$STATE_RS1" | jq -r '.policy_digest')
grep -qF "unchanged (inherited predecessor snapshot/digest: $DIGEST_G1)" "$CONT_FILE" \
  && pass "resume without --policy-file inherits predecessor policy snapshot/digest unchanged" \
  || fail "resume without --policy-file did not record an unchanged digest linkage note"

# 別 runtime で、明示 --policy-file を渡した resume が前世代の snapshot ファイル
# を上書きせず新しい content-addressed path を得ること、および continuation
# bundle に old_digest -> new_digest の監査記録が残ることを検証する。
NAME_REPOLICY="resume-repolicy"
RIDR1=$(bash "$AGENTCTL" start --name "$NAME_REPOLICY" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mr1")
STATE_RP1=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME_REPOLICY/state.json")
SNAPSHOT_PATH_RP1=$(echo "$STATE_RP1" | jq -r '.policy_snapshot_path')
DIGEST_RP1=$(echo "$STATE_RP1" | jq -r '.policy_digest')
SNAPSHOT_CONTENT_RP1=$(cat "$SNAPSHOT_PATH_RP1")
tmux kill-session -t "agentctl-$NAME_REPOLICY" >/dev/null 2>&1 || true

POLICY_REPOLICY="$WORKROOT/policy-repolicy.json"
echo "{\"version\":1,$POLICY_PERMISSIONS_ALL_FALSE,\"scope\":{\"repositories\":[{\"id\":\"primary\",\"git_common_dir\":\"/tmp/repolicy/.git\",\"github_repo\":\"repolicy/repolicy\",\"allowed_worktree_roots\":[]}],\"remotes\":[],\"production_targets\":[]}}" >"$POLICY_REPOLICY"
RIDR2=$(bash "$AGENTCTL" resume --name "$NAME_REPOLICY" --from-runtime-id "$RIDR1" --policy-file "$POLICY_REPOLICY")
STATE_RP2=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME_REPOLICY/state.json")
SNAPSHOT_PATH_RP2=$(echo "$STATE_RP2" | jq -r '.policy_snapshot_path')
DIGEST_RP2=$(echo "$STATE_RP2" | jq -r '.policy_digest')

[ -f "$SNAPSHOT_PATH_RP1" ] && [ "$(cat "$SNAPSHOT_PATH_RP1")" = "$SNAPSHOT_CONTENT_RP1" ] \
  && pass "resume with an explicit --policy-file leaves the predecessor's policy snapshot file byte-unchanged" \
  || fail "resume with --policy-file mutated/removed the predecessor's policy snapshot file"

[ "$SNAPSHOT_PATH_RP2" != "$SNAPSHOT_PATH_RP1" ] \
  && pass "resume with an explicit --policy-file gets a new, distinct snapshot path (not overwritten in place)" \
  || fail "resume with --policy-file reused the predecessor's snapshot path: $SNAPSHOT_PATH_RP2"

CONT_FILE_RP="$WORKROOT/state/agentctl/runtimes/$NAME_REPOLICY/continuation.txt"
grep -qF "explicit policy change: predecessor digest $DIGEST_RP1 -> this generation digest $DIGEST_RP2" "$CONT_FILE_RP" \
  && pass "resume with an explicit --policy-file records old_digest -> new_digest linkage in the continuation bundle" \
  || fail "resume with --policy-file did not record the digest change linkage"

bash "$AGENTCTL" stop --name "$NAME_REPOLICY" --runtime-id "$RIDR2" >/dev/null 2>/dev/null || true
bash "$AGENTCTL" cleanup --name "$NAME_REPOLICY" --runtime-id "$RIDR2" >/dev/null 2>/dev/null || true
tmux kill-session -t "agentctl-$NAME_REPOLICY" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_REPOLICY"

# --- operation event log: unique operation_id / runtime fencing / no-payload-leak (tui-paste transport) 検証 -----------------------------------------------------------
EVENTS_RS="$WORKROOT/state/agentctl/runtimes/$NAME_RS/events.jsonl"
if [ -f "$EVENTS_RS" ]; then
  grep -q "m1" "$EVENTS_RS" \
    && fail "events.jsonl (tui-paste transport) leaked mission payload content" \
    || pass "events.jsonl (tui-paste transport) contains no payload content"
  START_EVT=$(jq -c 'select(.operation == "start")' "$EVENTS_RS" | head -1)
  RESUME_EVT=$(jq -c 'select(.operation == "resume")' "$EVENTS_RS" | head -1)
  START_OPID=$(echo "$START_EVT" | jq -r '.operation_id')
  RESUME_OPID=$(echo "$RESUME_EVT" | jq -r '.operation_id')
  [ -n "$START_OPID" ] && [ -n "$RESUME_OPID" ] && [ "$START_OPID" != "$RESUME_OPID" ] \
    && pass "events.jsonl assigns a unique operation_id per operation (start != resume)" \
    || fail "events.jsonl operation_id was not unique across start/resume (start=$START_OPID resume=$RESUME_OPID)"
  START_RID=$(echo "$START_EVT" | jq -r '.runtime_id')
  RESUME_RID=$(echo "$RESUME_EVT" | jq -r '.runtime_id')
  [ "$START_RID" = "$RID1" ] && [ "$RESUME_RID" = "$RID2" ] \
    && pass "events.jsonl fences each event to its own generation's runtime_id (start=$RID1, resume=$RID2)" \
    || fail "events.jsonl runtime_id fencing mismatch (start=$START_RID want $RID1, resume=$RESUME_RID want $RID2)"
  echo "$RESUME_EVT" | jq -e '.transport == "fake-sink" and .result.submission == "submitted" and .result.acceptance == "unknown"' >/dev/null \
    && pass "events.jsonl records submission=submitted/acceptance=unknown for TUI-paste fallback (never claims accepted from screen heuristics)" \
    || fail "events.jsonl resume event fields unexpected: $RESUME_EVT"
else
  fail "start/resume via fake backend did not write an events.jsonl entry"
fi

tmux kill-session -t "agentctl-$NAME_RS" >/dev/null 2>&1 || true

# --- resume continuation bundle: embedded mission must be byte-exact 検証 -----------------------------------------------------------

# `$(cat file)` は末尾改行を無条件に落とすため、continuation bundle への
# mission 埋め込みで command substitution/関数の string 引数を経由すると、
# 複数の末尾改行や特殊文字を含む任意本文が byte-exact でなくなる。
NAME_RB="resume-bytes-t1"
MISSION_RB_FILE="$WORKROOT/mission-rb.txt"
printf 'line one\nspecial: $x \\ "quo'"'"'tes'"'"' `backtick` 日本語\nline two\n\n\n' >"$MISSION_RB_FILE"
RID1_RB=$(bash "$AGENTCTL" start --name "$NAME_RB" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-file "$MISSION_RB_FILE")
tmux kill-session -t "agentctl-$NAME_RB" >/dev/null 2>&1 || true
RID2_RB=$(bash "$AGENTCTL" resume --name "$NAME_RB" --from-runtime-id "$RID1_RB")
[ -n "$RID2_RB" ] || fail "resume (byte-exact test) did not produce a new runtime_id"

CONT_FILE_RB="$WORKROOT/state/agentctl/runtimes/$NAME_RB/continuation.txt"
if diff <(od -c "$MISSION_RB_FILE") <(sed -n '/^=== ORIGINAL MISSION ===$/,$p' "$CONT_FILE_RB" | tail -n +2 | od -c) >/tmp/agentctl-mission-bytes-diff; then
  pass "continuation bundle embeds the original mission byte-exact (multiple trailing newlines, special chars, multi-byte text preserved)"
else
  fail "continuation bundle mangled mission bytes: $(cat /tmp/agentctl-mission-bytes-diff)"
fi

bash "$AGENTCTL" stop --name "$NAME_RB" --runtime-id "$RID2_RB" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME_RB" --runtime-id "$RID2_RB" >/dev/null

if bash "$AGENTCTL" resume --name "$NAME_RS" --from-runtime-id "$RID1" 2>/tmp/agentctl-resume-err2; then
  fail "resume with stale --from-runtime-id should be rejected"
else
  grep -q "stale --from-runtime-id" /tmp/agentctl-resume-err2 && pass "resume with stale --from-runtime-id is rejected" \
    || fail "resume stale from-runtime-id error message missing: $(cat /tmp/agentctl-resume-err2)"
fi

bash "$AGENTCTL" stop --name "$NAME_RS" --runtime-id "$RID2" >/dev/null

if bash "$AGENTCTL" complete --name "$NAME_RS" --runtime-id "$RID2" 2>/tmp/agentctl-complete-err; then
  fail "complete without a done/blocked/failed manifest mission_status should be rejected"
else
  grep -q "mission_status" /tmp/agentctl-complete-err && pass "complete refuses runtime whose manifest mission_status is still 'running'" \
    || fail "complete rejection message missing mission_status detail: $(cat /tmp/agentctl-complete-err)"
fi

MANIFEST_PATH="$WORKROOT/state/agentctl/runtimes/$NAME_RS/manifest.json"
jq '.mission_status = "done"' "$MANIFEST_PATH" >"$MANIFEST_PATH.tmp" && mv "$MANIFEST_PATH.tmp" "$MANIFEST_PATH"

bash "$AGENTCTL" complete --name "$NAME_RS" --runtime-id "$RID2" >/dev/null \
  && pass "complete succeeds once manifest mission_status is done" \
  || fail "complete failed with a done manifest"

RECONCILE_RS=$(bash "$AGENTCTL" status --name "$NAME_RS" --json | jq -r '.reconcile')
[ "$RECONCILE_RS" = "stale" ] || [ "$RECONCILE_RS" = "absent" ] \
  && pass "complete tears down the tmux session (reconcile=$RECONCILE_RS)" \
  || fail "complete did not tear down the tmux session (reconcile=$RECONCILE_RS)"

bash "$AGENTCTL" cleanup --name "$NAME_RS" --runtime-id "$RID2" >/dev/null 2>&1 || true

[ -f "$EVENTS_RS" ] \
  && fail "cleanup did not remove events.jsonl along with the runtime dir" \
  || pass "cleanup removes events.jsonl along with the rest of the runtime state"

# --- codex operation-specific secure copy: TOCTOU/no-follow, bootstrap paste 検証 -----------------------------------------------------------

# agentctl_secure_create は dest が (symlink 含め) 既存なら追従/上書きせず fail
# closed すること、および衝突が無ければ mode 通りの新規ファイルを作成すること
# の両方を検証する。
SECURE_DIR="$WORKROOT/secure-create"
mkdir -p "$SECURE_DIR"
SECURE_TARGET="$SECURE_DIR/attacker-target.txt"
echo -n "pre-existing" >"$SECURE_TARGET"
SECURE_DEST="$SECURE_DIR/planted-symlink.txt"
ln -s "$SECURE_TARGET" "$SECURE_DEST"
if echo -n "payload" | bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_secure_create '$SECURE_DEST' 0600
" 2>/tmp/agentctl-secure-symlink-err; then
  fail "agentctl_secure_create should refuse a pre-planted symlink destination"
else
  if grep -q "already exists" /tmp/agentctl-secure-symlink-err && [ "$(cat "$SECURE_TARGET")" = "pre-existing" ]; then
    pass "agentctl_secure_create fails closed on a pre-planted symlink destination (target left untouched)"
  else
    fail "agentctl_secure_create symlink refusal did not behave as expected: $(cat /tmp/agentctl-secure-symlink-err)"
  fi
fi

SECURE_FRESH="$SECURE_DIR/fresh.txt"
if echo -n "fresh-payload" | bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  agentctl_secure_create '$SECURE_FRESH' 0600
"; then
  fresh_mode=$(stat -c '%a' "$SECURE_FRESH" 2>/dev/null)
  fresh_content=$(cat "$SECURE_FRESH")
  [ "$fresh_mode" = "600" ] && [ "$fresh_content" = "fresh-payload" ] \
    && pass "agentctl_secure_create creates a fresh 0600 file with exact stdin content when dest does not exist" \
    || fail "agentctl_secure_create fresh-file result unexpected (mode=$fresh_mode content=$fresh_content)"
else
  fail "agentctl_secure_create unexpectedly failed creating a fresh (non-colliding) destination"
fi

# agentctl_deliver_body の codex 分岐: 長文 body を直接 paste せず、
# operation-specific file への短い bootstrap (path+sha256) だけを paste する
# こと、その operation file が呼び出し後も byte-exact な内容のまま (immutable
# に) 残ることを検証する。
DELIVER_DIR="$WORKROOT/deliver-codex"
mkdir -p "$DELIVER_DIR"
DELIVER_BODY="$WORKROOT/deliver-body.txt"
python3 -c 'print("\n".join(f"日本語 line {i}" for i in range(200)))' >"$DELIVER_BODY"
DELIVER_SESS="agentctl-deliver-codex-check"
DELIVER_OUT="$WORKROOT/deliver-out.txt"
tmux new-session -d -s "$DELIVER_SESS" -- bash -c "cat >'$DELIVER_OUT'"
sleep 0.2
AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS=0.3 AGENTCTL_READY_POLL_SECONDS=0.1 bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  source '$REPO_ROOT/home/bin/agentctl-backend-codex.sh'
  agentctl_deliver_body codex '$DELIVER_SESS' '$DELIVER_DIR' '$DELIVER_BODY' test-runtime-id test-op
"
sleep 0.2
tmux kill-session -t "$DELIVER_SESS" >/dev/null 2>&1 || true

if grep -q "日本語" "$DELIVER_OUT" 2>/dev/null; then
  fail "agentctl_deliver_body(codex) leaked the mission body into the pane instead of a short bootstrap"
else
  op_file=$(find "$DELIVER_DIR" -maxdepth 1 -name 'codex-op-*.txt' | head -1)
  if [ -z "$op_file" ]; then
    fail "agentctl_deliver_body(codex) did not create an operation-specific file under the runtime dir"
  else
    op_mode=$(stat -c '%a' "$op_file")
    op_sha=$(sha256sum "$op_file" | awk '{print $1}')
    if cmp -s "$op_file" "$DELIVER_BODY" \
      && [ "$op_mode" = "600" ] \
      && grep -qF "$op_file" "$DELIVER_OUT" \
      && grep -qF "$op_sha" "$DELIVER_OUT"; then
      pass "agentctl_deliver_body(codex) pastes only a short path+sha256 bootstrap and preserves a byte-exact 0600 operation file"
    else
      fail "agentctl_deliver_body(codex) operation file/bootstrap mismatch (mode=$op_mode, file=$op_file)"
    fi

    # --- operation event log (metadata-only, no payload) 検証 -----------------------------------------------------------
    EVENTS_FILE_DELIVER="$DELIVER_DIR/events.jsonl"
    if [ -f "$EVENTS_FILE_DELIVER" ]; then
      EVT_MODE=$(stat -c '%a' "$EVENTS_FILE_DELIVER")
      [ "$EVT_MODE" = "600" ] && pass "events.jsonl is created with mode 0600" \
        || fail "events.jsonl mode is $EVT_MODE, expected 600"
      grep -q "日本語" "$EVENTS_FILE_DELIVER" \
        && fail "events.jsonl leaked mission payload content" \
        || pass "events.jsonl contains no payload content (only sha256/metadata)"
      EVT_LINE=$(cat "$EVENTS_FILE_DELIVER")
      echo "$EVT_LINE" | jq -e \
        --arg rid test-runtime-id --arg op test-op --arg transport codex-bootstrap-file --arg sha "$op_sha" \
        '.runtime_id == $rid and .operation == $op and .transport == $transport and .body_sha256 == $sha
         and .result.submission == "submitted" and .result.acceptance == "unknown"' >/dev/null \
        && pass "events.jsonl records submission=submitted/acceptance=unknown metadata for the delivery (never claims accepted from screen heuristics)" \
        || fail "events.jsonl event fields mismatch: $EVT_LINE"
    else
      fail "agentctl_deliver_body did not write an events.jsonl entry"
    fi
  fi
fi


# Codex steer は busy TUI への Enter が active turn steering にならないよう、
# sentinel で確立した session_id に `codex queue` で別 follow-up を積む。
# 本文は argv に載せず operation file に保持し、queue argv は path+sha bootstrap のみ。
QUEUE_HOME="$WORKROOT/codex-queue-home"
QUEUE_DIR="$WORKROOT/deliver-codex-queue"
QUEUE_BODY="$WORKROOT/deliver-codex-queue-body.txt"
QUEUE_ARGS="$WORKROOT/codex-queue-args.txt"
QUEUE_SID="01a00000-1111-2222-3333-444444444444"
QUEUE_RID="queue-runtime-id"
QUEUE_NAME="queue-runtime"
QUEUE_CWD="$WORKROOT/queue-cwd"
QUEUE_POLICY="$QUEUE_DIR/policy.snapshot.queue.json"
mkdir -p "$QUEUE_HOME/.local/state/agentctl/codex-hook-bindings/sessions" "$QUEUE_DIR" "$QUEUE_CWD"
printf 'queue 日本語 payload\nsecond line\n' >"$QUEUE_BODY"
valid_policy >"$QUEUE_POLICY"
QUEUE_POLICY_DIGEST="sha256:$(jq -S -c . "$QUEUE_POLICY" | sha256sum | awk '{print $1}')"
jq -n --arg name "$QUEUE_NAME" --arg rid "$QUEUE_RID" --arg cwd "$QUEUE_CWD" \
  --arg policy "$QUEUE_POLICY" --arg digest "$QUEUE_POLICY_DIGEST" \
  '{schema_version:1,name:$name,backend:"codex",runtime_id:$rid,cwd:$cwd,tmux_session:"unused-for-queue",
    pane_id:"%queue",pane_pid:1,pane_pid_start:"1",started_at:"2026-09-11T00:00:00Z",
    policy_snapshot_path:$policy,policy_digest:$digest,status:"running"}' >"$QUEUE_DIR/state.json"
QUEUE_KEY=$(printf '%s' "$QUEUE_SID" | sha256sum | awk '{print $1}')
jq -n --arg sid "$QUEUE_SID" --arg rid "$QUEUE_RID" --arg name "$QUEUE_NAME" --arg dir "$QUEUE_DIR" \
  --arg cwd "$QUEUE_CWD" --arg policy "$QUEUE_POLICY" --arg digest "$QUEUE_POLICY_DIGEST" \
  '{schema_version:1,session_id:$sid,runtime_id:$rid,name:$name,backend:"codex",runtime_dir:$dir,
    policy_snapshot:$policy,policy_digest:$digest,cwd:$cwd}' \
  >"$QUEUE_HOME/.local/state/agentctl/codex-hook-bindings/sessions/$QUEUE_KEY.json"
cat >"$WORKROOT/bin/codex" <<'STUBCODEX'
#!/bin/bash
printf '%s\n' "$@" >"$AGENTCTL_TEST_CODEX_QUEUE_ARGS"
printf 'call\n' >>"${AGENTCTL_TEST_CODEX_QUEUE_CALLS:-/dev/null}"
[ "${AGENTCTL_TEST_CODEX_QUEUE_FAIL:-0}" = "1" ] && exit 93
exit 0
STUBCODEX
chmod +x "$WORKROOT/bin/codex"
if HOME="$QUEUE_HOME" AGENTCTL_TEST_CODEX_QUEUE_ARGS="$QUEUE_ARGS" bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  source '$REPO_ROOT/home/bin/agentctl-backend-codex.sh'
  agentctl_codex_runtime_generation_is_live() { return 0; }
  agentctl_deliver_body codex nonexistent-pane '$QUEUE_DIR' '$QUEUE_BODY' '$QUEUE_RID' steer
"; then
  if grep -qx -- '--thread' "$QUEUE_ARGS" \
    && grep -qx -- "$QUEUE_SID" "$QUEUE_ARGS" \
    && grep -qx -- '--message' "$QUEUE_ARGS" \
    && ! grep -qF 'queue 日本語 payload' "$QUEUE_ARGS"; then
    pass "Codex steer uses codex queue for the bound session and keeps the steer body out of argv"
  else
    fail "Codex steer queue argv contract mismatch: $(tr '\n' ' ' <"$QUEUE_ARGS" 2>/dev/null)"
  fi
else
  fail "Codex steer should use codex queue instead of TUI paste for a bound session"
fi

# queue transport は validated session binding が欠落した状態では delivery 前に
# fail closed (5) し、別 session へ推測配送しない。
QUEUE_BINDING="$QUEUE_HOME/.local/state/agentctl/codex-hook-bindings/sessions/$QUEUE_KEY.json"
mv "$QUEUE_BINDING" "$QUEUE_BINDING.saved"
if HOME="$QUEUE_HOME" AGENTCTL_TEST_CODEX_QUEUE_ARGS="$QUEUE_ARGS" bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  source '$REPO_ROOT/home/bin/agentctl-backend-codex.sh'
  agentctl_codex_runtime_generation_is_live() { return 0; }
  agentctl_deliver_body codex nonexistent-pane '$QUEUE_DIR' '$QUEUE_BODY' '$QUEUE_RID' steer
" >/dev/null 2>&1; then
  fail "Codex steer without a validated session binding should fail before delivery"
else
  rc=$?
  [ "$rc" -eq 5 ]     && pass "Codex steer without a validated session binding fails closed before delivery (exit 5)"     || fail "Codex steer without a validated session binding exited $rc, expected 5"
fi
mv "$QUEUE_BINDING.saved" "$QUEUE_BINDING"

# binding解決後〜delivery直前にgenerationが失効した場合、2回目の再検証でfail closedし、
# codex queueを一度も呼ばない。ここではliveness helper自体は別unitで実tmux検証済みなので、
# resolverの1回目だけ成功・2回目失敗を決定的に注入する。
QUEUE_RACE_CALLS="$WORKROOT/codex-queue-race-calls.txt"
: >"$QUEUE_RACE_CALLS"
if HOME="$QUEUE_HOME" AGENTCTL_TEST_CODEX_QUEUE_ARGS="$QUEUE_ARGS" AGENTCTL_TEST_CODEX_QUEUE_CALLS="$QUEUE_RACE_CALLS" bash -c "
  source '$REPO_ROOT/home/bin/agentctl-common.sh'
  source '$REPO_ROOT/home/bin/agentctl-backend-codex.sh'
  agentctl_codex_hook_session_id_for_runtime() {
    [ ! -e '$WORKROOT/codex-queue-resolved-once' ] || return 1
    : >'$WORKROOT/codex-queue-resolved-once'
    printf '%s' '$QUEUE_SID'
  }
  agentctl_deliver_body codex nonexistent-pane '$QUEUE_DIR' '$QUEUE_BODY' '$QUEUE_RID' steer
" >/dev/null 2>&1; then
  queue_race_rc=0
else
  queue_race_rc=$?
fi
if [ "$queue_race_rc" -eq 5 ] && [ ! -s "$QUEUE_RACE_CALLS" ]; then
  pass "Codex steer revalidates generation immediately before queue and refuses a stale binding without delivery"
else
  fail "Codex steer stale-binding race contract mismatch (rc=$queue_race_rc queue_calls=$(wc -l <"$QUEUE_RACE_CALLS"))"
fi

# codex queue 自体が non-zero の場合、server 側受理の有無は断定できない。
# 1 回だけ試行し result=unknown 相当 (return 1) にして自動再送しない。
QUEUE_CALLS="$WORKROOT/codex-queue-calls.txt"
: >"$QUEUE_CALLS"
if HOME="$QUEUE_HOME" AGENTCTL_TEST_CODEX_QUEUE_ARGS="$QUEUE_ARGS" AGENTCTL_TEST_CODEX_QUEUE_CALLS="$QUEUE_CALLS" \
  AGENTCTL_TEST_CODEX_QUEUE_FAIL=1 bash -c "
    source '$REPO_ROOT/home/bin/agentctl-common.sh'
    source '$REPO_ROOT/home/bin/agentctl-backend-codex.sh'
  agentctl_codex_runtime_generation_is_live() { return 0; }
    agentctl_deliver_body codex nonexistent-pane '$QUEUE_DIR' '$QUEUE_BODY' '$QUEUE_RID' steer
  " >/dev/null 2>&1; then
  queue_fail_rc=0
else
  queue_fail_rc=$?
fi
queue_calls=$(wc -l <"$QUEUE_CALLS")
if [ "$queue_fail_rc" -eq 1 ] && [ "$queue_calls" -eq 1 ]; then
  pass "Codex queue failure remains acceptance=unknown and is not auto-retried"
else
  fail "Codex queue failure contract mismatch (rc=$queue_fail_rc calls=$queue_calls; expected rc=1 calls=1)"
fi

# --- state dir path にスペースを含む場合の policy snapshot path/digest 受け渡し -----------

SPACED_ROOT=$(mktemp -d)"/state dir"
mkdir -p "$SPACED_ROOT"
SPACED_WORKTREE="$SPACED_ROOT/worktree"
mkdir -p "$SPACED_WORKTREE"
SPACED_POLICY="$SPACED_ROOT/policy.json"
cat >"$SPACED_POLICY" <<JSON
{"version":1,$POLICY_PERMISSIONS_ALL_FALSE,"scope":{"repositories":[{"id":"primary","git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$SPACED_WORKTREE"]}],"remotes":[],"production_targets":[]}}
JSON

RID_SPACED=$(XDG_STATE_HOME="$SPACED_ROOT/xdg" bash "$AGENTCTL" start --name spacedstate --cwd "$SPACED_WORKTREE" --backend fake --policy-file "$SPACED_POLICY" --mission-stdin <<<"m-spaced" 2>/tmp/agentctl-spaced-err)
if [ -n "$RID_SPACED" ]; then
  STATUS_SPACED=$(XDG_STATE_HOME="$SPACED_ROOT/xdg" bash "$AGENTCTL" status --name spacedstate --json 2>/dev/null | jq -r '.reconcile')
  [ "$STATUS_SPACED" = "running" ] && pass "start succeeds when the state dir path contains a space (policy snapshot path/digest survive the read)" \
    || fail "start with a spaced state dir did not reach reconcile=running: $STATUS_SPACED"
else
  fail "start with a spaced state dir path failed: $(cat /tmp/agentctl-spaced-err 2>/dev/null)"
fi
XDG_STATE_HOME="$SPACED_ROOT/xdg" bash "$AGENTCTL" stop --name spacedstate --runtime-id "$RID_SPACED" >/dev/null 2>&1 || true
XDG_STATE_HOME="$SPACED_ROOT/xdg" bash "$AGENTCTL" cleanup --name spacedstate --runtime-id "$RID_SPACED" >/dev/null 2>&1 || true

# --- canonical CLI contract: positional <name> + --agent, --name/--backend compat aliases 検証 -----------------------------------------------------------

NAME_CANON="rtcanon"
RID_CANON=$(bash "$AGENTCTL" start "$NAME_CANON" --agent fake --cwd "$WORKROOT/worktree" --policy-file "$POLICY_OK" --mission-stdin <<<"canon mission")
[[ "$RID_CANON" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  && pass "start accepts canonical positional <name> + --agent form" \
  || fail "start with positional name + --agent did not publish a runtime: $RID_CANON"
[ "$(bash "$AGENTCTL" status "$NAME_CANON" --json | jq -r '.reconcile')" = "running" ] \
  && pass "status accepts canonical positional <name> form" \
  || fail "status with positional name did not report running"
bash "$AGENTCTL" steer "$NAME_CANON" --runtime-id "$RID_CANON" --stdin <<<"canon steer" >/dev/null \
  && pass "steer accepts canonical positional <name> form" \
  || fail "steer with positional name failed"
bash "$AGENTCTL" interrupt "$NAME_CANON" --runtime-id "$RID_CANON" >/dev/null \
  && pass "interrupt accepts canonical positional <name> form" \
  || fail "interrupt with positional name failed"
bash "$AGENTCTL" stop "$NAME_CANON" --runtime-id "$RID_CANON" >/dev/null \
  && pass "stop accepts canonical positional <name> form" \
  || fail "stop with positional name failed"
bash "$AGENTCTL" cleanup "$NAME_CANON" --runtime-id "$RID_CANON" >/dev/null \
  && pass "cleanup accepts canonical positional <name> form" \
  || fail "cleanup with positional name failed"

# resume は caller が --cwd/--agent を渡さず、predecessor generation の state から継承する。
NAME_RESUME_CANON="rtresumecanon"
RID_RC1=$(bash "$AGENTCTL" start "$NAME_RESUME_CANON" --agent fake --cwd "$WORKROOT/worktree" --policy-file "$POLICY_OK" --mission-stdin <<<"resume canon mission")
bash "$AGENTCTL" stop "$NAME_RESUME_CANON" --runtime-id "$RID_RC1" >/dev/null
RID_RC2=$(bash "$AGENTCTL" resume "$NAME_RESUME_CANON" --from-runtime-id "$RID_RC1")
if [ -n "$RID_RC2" ] && [ "$RID_RC2" != "$RID_RC1" ]; then
  pass "resume with canonical positional <name> and no --cwd/--agent inherits the predecessor's cwd/backend"
else
  fail "resume without --cwd/--agent did not publish a fresh generation: $RID_RC2"
fi
[ "$(bash "$AGENTCTL" status "$NAME_RESUME_CANON" --json | jq -r '.backend')" = "fake" ] \
  && pass "resumed generation kept the inherited backend" \
  || fail "resumed generation lost the inherited backend"
bash "$AGENTCTL" stop "$NAME_RESUME_CANON" --runtime-id "$RID_RC2" >/dev/null
bash "$AGENTCTL" cleanup "$NAME_RESUME_CANON" --runtime-id "$RID_RC2" >/dev/null

# v8 正典構文: resume は cwd/backend を predecessor state から厳密に継承する。
# --cwd/--agent/--backend override は継続 identity を変えてしまうため usage
# error (exit 2) として拒否しなければならない (cwd/backend の再指定を許可しない)。
NAME_RESUME_STRICT="rtresumestrict"
RID_RSTRICT1=$(bash "$AGENTCTL" start "$NAME_RESUME_STRICT" --agent fake --cwd "$WORKROOT/worktree" --policy-file "$POLICY_OK" --mission-stdin <<<"resume strict mission")
bash "$AGENTCTL" stop "$NAME_RESUME_STRICT" --runtime-id "$RID_RSTRICT1" >/dev/null

bash "$AGENTCTL" resume "$NAME_RESUME_STRICT" --cwd "$WORKROOT/worktree" --from-runtime-id "$RID_RSTRICT1" >/dev/null 2>/tmp/agentctl-resume-cwd-override-err
[ "$?" -eq 2 ] && pass "resume with an explicit --cwd override is rejected as a usage error (exit 2)" \
  || fail "resume --cwd override did not exit 2: $(cat /tmp/agentctl-resume-cwd-override-err)"

bash "$AGENTCTL" resume "$NAME_RESUME_STRICT" --agent fake --from-runtime-id "$RID_RSTRICT1" >/dev/null 2>/tmp/agentctl-resume-agent-override-err
[ "$?" -eq 2 ] && pass "resume with an explicit --agent override is rejected as a usage error (exit 2)" \
  || fail "resume --agent override did not exit 2: $(cat /tmp/agentctl-resume-agent-override-err)"

bash "$AGENTCTL" resume "$NAME_RESUME_STRICT" --backend fake --from-runtime-id "$RID_RSTRICT1" >/dev/null 2>/tmp/agentctl-resume-backend-override-err
[ "$?" -eq 2 ] && pass "resume with an explicit --backend override is rejected as a usage error (exit 2)" \
  || fail "resume --backend override did not exit 2: $(cat /tmp/agentctl-resume-backend-override-err)"

RID_RSTRICT2=$(bash "$AGENTCTL" resume "$NAME_RESUME_STRICT" --from-runtime-id "$RID_RSTRICT1")
bash "$AGENTCTL" stop "$NAME_RESUME_STRICT" --runtime-id "$RID_RSTRICT2" >/dev/null
bash "$AGENTCTL" cleanup "$NAME_RESUME_STRICT" --runtime-id "$RID_RSTRICT2" >/dev/null

# --- typed exit code contract の検証: postcondition met=0, usage/schema error=2,
# target/subject absent=3、ownership/conflict/refused=4、transport failure=5 -----------------------------------------------------------

NAME_EXIT="rtexit"
STALE_RID="00000000-0000-0000-0000-000000000000"
RID_EXIT=$(bash "$AGENTCTL" start --name "$NAME_EXIT" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"exit contract mission")

bash "$AGENTCTL" start --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m" >/dev/null 2>/tmp/agentctl-exit-usage-err
[ "$?" -eq 2 ] && pass "start without --name exits 2 (usage/schema error)" \
  || fail "start without --name did not exit 2: $(cat /tmp/agentctl-exit-usage-err)"

bash "$AGENTCTL" >/dev/null 2>/tmp/agentctl-exit-nocommand-err
[ "$?" -eq 2 ] && pass "invoking agentctl with no command exits 2 (usage/schema error)" \
  || fail "no command did not exit 2: $(cat /tmp/agentctl-exit-nocommand-err)"
bash "$AGENTCTL" no-such-command >/dev/null 2>/tmp/agentctl-exit-unknowncommand-err
[ "$?" -eq 2 ] && pass "invoking agentctl with an unknown command exits 2 (usage/schema error)" \
  || fail "unknown command did not exit 2: $(cat /tmp/agentctl-exit-unknowncommand-err)"

# 値を取る option が末尾に置かれた場合も shell の unbound-variable ではなく usage error にする。
for spec in "start --name" "status --name" "steer --runtime-id" "logs --lines" "attach --runtime-id" "interrupt --runtime-id" "stop --runtime-id" "cleanup --runtime-id" "resume --from-runtime-id" "complete --runtime-id"; do
  cmd=${spec%% *}
  flag=${spec#* }
  bash "$AGENTCTL" "$cmd" "$flag" >/dev/null 2>"$WORKROOT/missing-value.err"
  rc=$?
  [ "$rc" -eq 2 ] && pass "$cmd $flag without value exits 2" \
    || fail "$cmd $flag without value exited $rc instead of 2: $(cat "$WORKROOT/missing-value.err")"
done

# test-only fake command injection は public CLI で受理しない。
bash "$AGENTCTL" start --name fakecmdreject --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin --fake-command true \
  <<<"fake command must be rejected" >/dev/null 2>"$WORKROOT/fake-command.err"
FAKE_COMMAND_RC=$?
[ "$FAKE_COMMAND_RC" -eq 2 ] && grep -q "unknown option.*--fake-command" "$WORKROOT/fake-command.err" \
  && pass "public start rejects test-only --fake-command" \
  || fail "public start accepted --fake-command or returned wrong error (rc=$FAKE_COMMAND_RC): $(cat "$WORKROOT/fake-command.err")"

bash "$AGENTCTL" status --name "no-such-$NAME_EXIT" --json >/dev/null 2>/tmp/agentctl-exit-status-absent-err
[ "$?" -eq 0 ] && pass "status for an absent runtime exits 0 (reconcile=absent is a valid, non-error postcondition)" \
  || fail "status for an absent runtime did not exit 0: $(cat /tmp/agentctl-exit-status-absent-err)"

bash "$AGENTCTL" steer --name "$NAME_EXIT" --runtime-id "$STALE_RID" --stdin <<<"x" >/dev/null 2>/tmp/agentctl-exit-steer-stale-err
[ "$?" -eq 4 ] && pass "steer with a stale --runtime-id exits 4 (ownership/conflict/refused)" \
  || fail "steer with stale --runtime-id did not exit 4: $(cat /tmp/agentctl-exit-steer-stale-err)"
bash "$AGENTCTL" steer --name "no-such-$NAME_EXIT" --runtime-id "$STALE_RID" --stdin <<<"x" >/dev/null 2>/tmp/agentctl-exit-steer-absent-err
[ "$?" -eq 3 ] && pass "steer against a nonexistent name exits 3 (target absent)" \
  || fail "steer against a nonexistent name did not exit 3: $(cat /tmp/agentctl-exit-steer-absent-err)"

bash "$AGENTCTL" attach --name "$NAME_EXIT" --runtime-id "$STALE_RID" >/dev/null 2>/tmp/agentctl-exit-attach-stale-err
[ "$?" -eq 4 ] && pass "attach with a stale --runtime-id exits 4" \
  || fail "attach with stale --runtime-id did not exit 4: $(cat /tmp/agentctl-exit-attach-stale-err)"
bash "$AGENTCTL" attach --name "no-such-$NAME_EXIT" --runtime-id "$STALE_RID" >/dev/null 2>/tmp/agentctl-exit-attach-absent-err
[ "$?" -eq 3 ] && pass "attach against a nonexistent name exits 3" \
  || fail "attach against a nonexistent name did not exit 3: $(cat /tmp/agentctl-exit-attach-absent-err)"

bash "$AGENTCTL" interrupt --name "$NAME_EXIT" --runtime-id "$STALE_RID" >/dev/null 2>/tmp/agentctl-exit-interrupt-stale-err
[ "$?" -eq 4 ] && pass "interrupt with a stale --runtime-id exits 4" \
  || fail "interrupt with stale --runtime-id did not exit 4: $(cat /tmp/agentctl-exit-interrupt-stale-err)"

bash "$AGENTCTL" stop --name "$NAME_EXIT" --runtime-id "$RID_EXIT" >/dev/null 2>/tmp/agentctl-exit-stop-err
[ "$?" -eq 0 ] && pass "stop on a running runtime exits 0" || fail "stop did not exit 0: $(cat /tmp/agentctl-exit-stop-err)"
bash "$AGENTCTL" stop --name "$NAME_EXIT" --runtime-id "$RID_EXIT" >/dev/null 2>/tmp/agentctl-exit-stop-idem-err
[ "$?" -eq 0 ] && pass "idempotent re-stop of an already-stopped runtime still exits 0" \
  || fail "idempotent re-stop did not exit 0: $(cat /tmp/agentctl-exit-stop-idem-err)"

bash "$AGENTCTL" cleanup --name "$NAME_EXIT" --runtime-id "$RID_EXIT" >/dev/null 2>/tmp/agentctl-exit-cleanup-err
[ "$?" -eq 0 ] && pass "cleanup after stop exits 0" || fail "cleanup did not exit 0: $(cat /tmp/agentctl-exit-cleanup-err)"
bash "$AGENTCTL" cleanup --name "$NAME_EXIT" --runtime-id "$RID_EXIT" >/dev/null 2>/tmp/agentctl-exit-cleanup-idem-err
[ "$?" -eq 0 ] && pass "idempotent re-cleanup of an already-removed runtime still exits 0" \
  || fail "idempotent re-cleanup did not exit 0: $(cat /tmp/agentctl-exit-cleanup-idem-err)"

bash "$AGENTCTL" resume --name "no-such-$NAME_EXIT" --from-runtime-id "$STALE_RID" >/dev/null 2>/tmp/agentctl-exit-resume-absent-err
[ "$?" -eq 3 ] && pass "resume against a nonexistent name exits 3" \
  || fail "resume against a nonexistent name did not exit 3: $(cat /tmp/agentctl-exit-resume-absent-err)"
bash "$AGENTCTL" complete --name "no-such-$NAME_EXIT" --runtime-id "$STALE_RID" >/dev/null 2>/tmp/agentctl-exit-complete-absent-err
[ "$?" -eq 3 ] && pass "complete against a nonexistent name exits 3" \
  || fail "complete against a nonexistent name did not exit 3: $(cat /tmp/agentctl-exit-complete-absent-err)"

NAME_EXIT_RC="rtexitrc"
RID_EXIT_RC1=$(bash "$AGENTCTL" start --name "$NAME_EXIT_RC" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"exit rc mission")
bash "$AGENTCTL" resume --name "$NAME_EXIT_RC" --from-runtime-id "$RID_EXIT_RC1" >/dev/null 2>/tmp/agentctl-exit-resume-running-err
[ "$?" -eq 4 ] && pass "resume of a still-running predecessor exits 4 (reconcile must be exited/stale)" \
  || fail "resume of a still-running predecessor did not exit 4: $(cat /tmp/agentctl-exit-resume-running-err)"
bash "$AGENTCTL" stop --name "$NAME_EXIT_RC" --runtime-id "$RID_EXIT_RC1" >/dev/null
bash "$AGENTCTL" resume --name "$NAME_EXIT_RC" --from-runtime-id "$STALE_RID" >/dev/null 2>/tmp/agentctl-exit-resume-stale-err
[ "$?" -eq 4 ] && pass "resume with a stale --from-runtime-id exits 4" \
  || fail "resume with stale --from-runtime-id did not exit 4: $(cat /tmp/agentctl-exit-resume-stale-err)"

RID_EXIT_RC2=$(bash "$AGENTCTL" resume --name "$NAME_EXIT_RC" --from-runtime-id "$RID_EXIT_RC1")
bash "$AGENTCTL" complete --name "$NAME_EXIT_RC" --runtime-id "$RID_EXIT_RC2" >/dev/null 2>/tmp/agentctl-exit-complete-running-err
[ "$?" -eq 4 ] && pass "complete against a manifest whose mission_status is still 'running' exits 4" \
  || fail "complete against a still-running manifest did not exit 4: $(cat /tmp/agentctl-exit-complete-running-err)"

MANIFEST_EXIT_RC="$WORKROOT/state/agentctl/runtimes/$NAME_EXIT_RC/manifest.json"
jq '.mission_status = "done"' "$MANIFEST_EXIT_RC" >"$MANIFEST_EXIT_RC.tmp" && mv "$MANIFEST_EXIT_RC.tmp" "$MANIFEST_EXIT_RC"
bash "$AGENTCTL" stop --name "$NAME_EXIT_RC" --runtime-id "$RID_EXIT_RC2" >/dev/null
bash "$AGENTCTL" complete --name "$NAME_EXIT_RC" --runtime-id "$RID_EXIT_RC2" >/dev/null 2>/tmp/agentctl-exit-complete-done-err
[ "$?" -eq 0 ] && pass "complete succeeds (exits 0) once manifest mission_status is done" \
  || fail "complete with mission_status=done did not exit 0: $(cat /tmp/agentctl-exit-complete-done-err)"
bash "$AGENTCTL" cleanup --name "$NAME_EXIT_RC" --runtime-id "$RID_EXIT_RC2" >/dev/null

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl unit tests passed."
else
  echo "Some agentctl unit tests FAILED."
fi
exit "$FAILED"
