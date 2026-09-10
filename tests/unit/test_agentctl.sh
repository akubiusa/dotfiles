#!/bin/bash
# agentctl のユニットテスト。isolated XDG_STATE_HOME と fake backend/tmux server を使う。
# 実 Claude/Codex backend (Task 4/5) や remote/production E2E (Task 13/14) は対象外。
# shellcheck disable=SC2015,SC2329,SC2016
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
{"schema_version":1,$POLICY_PERMISSIONS_ALL_FALSE,"repository":{"git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}}
JSON
}

# --- Task 0: no git/gh calls -----------------------------------------------------------

if grep -nE '(^|[^a-zA-Z0-9_-])(git|gh)([[:space:]]|$)' "$REPO_ROOT/home/bin/executable_agentctl" "$REPO_ROOT/home/bin/agentctl-common.sh" \
   | grep -v '^\S*:[0-9]*:#' | grep -viE 'github_repo|git_common_dir|# |agent'; then
  fail "agentctl source appears to invoke git/gh directly"
else
  pass "agentctl keeper does not call git/gh"
fi

# --- Task 1: policy validation -----------------------------------------------------------

POLICY_OK="$WORKROOT/policy-ok.json"
valid_policy >"$POLICY_OK"

POLICY_BAD="$WORKROOT/policy-bad.json"
echo "{\"schema_version\":1,$POLICY_PERMISSIONS_ALL_FALSE,\"repository\":{\"git_common_dir\":\"relative/path\",\"github_repo\":\"acme/widgets\",\"allowed_worktree_roots\":[]}}" >"$POLICY_BAD"

if bash "$AGENTCTL" start --name t1 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_BAD" --mission-stdin <<<"mission" 2>/tmp/agentctl-t1-err; then
  fail "start with invalid policy (relative path) should fail closed"
else
  grep -q "policy validation failed" /tmp/agentctl-t1-err && pass "invalid policy is rejected fail-closed" || fail "invalid policy error message missing"
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
echo "{\"schema_version\":1,$POLICY_PERMISSIONS_LOCAL_WRITE_FALSE,\"repository\":{\"git_common_dir\":\"$REPO_FIXTURE/.git\",\"github_repo\":\"acme/widgets\",\"allowed_worktree_roots\":[\"$WORKROOT/worktree\"]}}" >"$POLICY_RO"
if bash "$AGENTCTL" start --name t4 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_RO" --mission-stdin <<<"m" 2>/tmp/agentctl-t4-err; then
  fail "fake backend must refuse start when local_write=false (no mechanical read-only mode)"
else
  grep -q "local_write=false" /tmp/agentctl-t4-err && pass "fake backend refuses local_write=false (no mechanical enforcement)" \
    || fail "fake backend local_write=false rejection message missing: $(cat /tmp/agentctl-t4-err)"
fi

# --- Task 2: runtime identity / locking / fencing -----------------------------------------------------------

NAME="rtA"
SINK="$WORKROOT/state/agentctl/runtimes/$NAME/fake-sink.txt"
RID=$(bash "$AGENTCTL" start --name "$NAME" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"hello mission")
if [[ "$RID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  pass "runtime_id looks like a UUID: $RID"
else
  fail "runtime_id is not a UUID: $RID"
fi

sleep 0.3
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

# --- logs/attach/interrupt: fencing/ownership -----------------------------------------------------------

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
# 後続の Task 3 byte-exact 転送テストと独立させて専用 runtime で検証する。
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
# されない (live E2E で実測確認済み)。fake backend の byte-exact sink を壊さず
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
    agentctl_submit_paste '$b' '$sess'
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

# --- backend readiness barrier: bracketed-paste + screen quiescence, fail-closed timeout -----------------------------------------------------------
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

# --- agentctl_deliver_body timeout path: failed/unknown event, fail-closed die preserved -----------------------------------------------------------
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

# --- Task 3: arbitrary text transport -----------------------------------------------------------

PAYLOAD_JA=$(python3 -c "print('こんにちは、これはテストです。'*70, end='')")
echo -n "$PAYLOAD_JA" >"$WORKROOT/payload-ja.txt"
SPECIAL_PAYLOAD=$'line1 with "quotes" and `backticks`\nline2 $(cmd) ; -leadingdash\nline3'
printf '%s' "$SPECIAL_PAYLOAD" >"$WORKROOT/payload-special.txt"

bash "$AGENTCTL" steer --name "$NAME" --runtime-id "$RID" --file "$WORKROOT/payload-ja.txt" >/dev/null
sleep 0.5
bash "$AGENTCTL" steer --name "$NAME" --runtime-id "$RID" --file "$WORKROOT/payload-special.txt" >/dev/null
sleep 0.5

if [ -f "$SINK" ]; then
  # sink は累積書き込みのため、start 時に届く initial mission に続けて steer
  # payload が並ぶ (先頭に mission.txt を cat して期待値を合わせる)。
  EXPECTED=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME/mission.txt" "$WORKROOT/payload-ja.txt" "$WORKROOT/payload-special.txt")
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

# --- concurrent steer serialization (no byte interleave) -----------------------------------------------------------

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
  MISSION2="$WORKROOT/state/agentctl/runtimes/$NAME2/mission.txt"
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

# --- PID reuse -> conflict -----------------------------------------------------------

NAME3="rtC"
bash "$AGENTCTL" start --name "$NAME3" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m3" >/dev/null
sleep 0.3
STATE3="$WORKROOT/state/agentctl/runtimes/$NAME3/state.json"
jq '.pane_pid_start = "bogus-start-token"' "$STATE3" >"$STATE3.tmp" && mv "$STATE3.tmp" "$STATE3"
RECONCILE3=$(bash "$AGENTCTL" status --name "$NAME3" --json | jq -r '.reconcile')
[ "$RECONCILE3" = "conflict" ] && pass "PID-start mismatch is classified as conflict" || fail "expected conflict, got $RECONCILE3"
tmux kill-session -t "agentctl-$NAME3" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME3"

# --- cleanup must refuse conflict (no auto-remediation) -----------------------------------------------------------

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

# --- blocked bootstrap self-terminates on bounded timeout -----------------------------------------------------------

NAME_TIMEOUT="rtTimeout"
AGENTCTL_TEST_BOOTSTRAP_TIMEOUT_SECONDS=1 AGENTCTL_TEST_FAULT_STAGE="pre_marker" \
  bash "$AGENTCTL" start --name "$NAME_TIMEOUT" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"mt" >/dev/null 2>/dev/null || true
sleep 2
if [ "$(tmux display-message -p -t "agentctl-$NAME_TIMEOUT" '#{pane_dead}' 2>/dev/null)" = "1" ]; then
  pass "blocked bootstrap self-terminates after bounded timeout"
else
  fail "blocked bootstrap did not self-terminate after bounded timeout"
fi
tmux kill-session -t "agentctl-$NAME_TIMEOUT" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/$NAME_TIMEOUT"

# --- steer --stdin does not leak temp file on rejection path -----------------------------------------------------------

TMP_BEFORE=$(find "$TMPDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
bash "$AGENTCTL" steer --name "$NAME_TIMEOUT" --runtime-id "00000000-0000-0000-0000-000000000000" --stdin <<<"leak-check" 2>/dev/null || true
TMP_AFTER=$(find "$TMPDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$TMP_BEFORE" = "$TMP_AFTER" ] && pass "steer --stdin does not leak temp file on rejection path" \
  || fail "steer --stdin leaked a temp file on rejection path ($TMP_BEFORE -> $TMP_AFTER)"

# --- stale / exited distinction -----------------------------------------------------------

NAME4="rtD"
RID4=$(bash "$AGENTCTL" start --name "$NAME4" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m4" --fake-command 'true')
sleep 0.5
RECONCILE4=$(bash "$AGENTCTL" status --name "$NAME4" --json | jq -r '.reconcile')
[ "$RECONCILE4" = "exited" ] && pass "dead pane with remain-on-exit is classified as exited" || fail "expected exited, got $RECONCILE4"
bash "$AGENTCTL" cleanup --name "$NAME4" --runtime-id "$RID4" >/dev/null

NAME5="rtE"
RID5=$(bash "$AGENTCTL" start --name "$NAME5" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m5")
sleep 0.3
tmux kill-session -t "agentctl-$NAME5" >/dev/null 2>&1
RECONCILE5=$(bash "$AGENTCTL" status --name "$NAME5" --json | jq -r '.reconcile')
[ "$RECONCILE5" = "stale" ] && pass "state without tmux session is classified as stale" || fail "expected stale, got $RECONCILE5"
bash "$AGENTCTL" cleanup --name "$NAME5" --runtime-id "$RID5" >/dev/null

# --- fault injection: launcher crash at 4 stages -> no unowned live agent -----------------------------------------------------------

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

# --- doctor -----------------------------------------------------------

DOCTOR_JSON=$(bash "$AGENTCTL" doctor --json)
echo "$DOCTOR_JSON" | jq -e --arg n "$NAME" '.runtimes | any(.name == $n)' >/dev/null \
  && pass "doctor lists active runtime" || fail "doctor missing active runtime: $DOCTOR_JSON"

# --- policy snapshot immutability -----------------------------------------------------------

SNAPSHOT_BEFORE=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME/policy.snapshot.json")
echo "{\"schema_version\":1,$POLICY_PERMISSIONS_ALL_FALSE,\"repository\":{\"git_common_dir\":\"/tmp/other/.git\",\"github_repo\":\"other/other\",\"allowed_worktree_roots\":[]}}" >"$POLICY_OK"
SNAPSHOT_AFTER=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME/policy.snapshot.json")
[ "$SNAPSHOT_BEFORE" = "$SNAPSHOT_AFTER" ] && pass "policy snapshot immutable after source file edit" || fail "policy snapshot changed after source edit"

bash "$AGENTCTL" stop --name "$NAME" --runtime-id "$RID" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME" --runtime-id "$RID" >/dev/null

# --- resume/complete -----------------------------------------------------------

NAME_RS="resume-t1"
RID1=$(bash "$AGENTCTL" start --name "$NAME_RS" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-stdin <<<"m1")

if bash "$AGENTCTL" resume --name "$NAME_RS" --cwd "$WORKROOT/worktree" --backend fake --from-runtime-id "$RID1" 2>/tmp/agentctl-resume-err; then
  fail "resume while runtime is still running should be rejected"
else
  pass "resume while still running is rejected (reconcile must be exited/stale)"
fi

tmux kill-session -t "agentctl-$NAME_RS" >/dev/null 2>&1 || true

RID2=$(bash "$AGENTCTL" resume --name "$NAME_RS" --cwd "$WORKROOT/worktree" --backend fake --from-runtime-id "$RID1")
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

# --- operation event log: unique operation_id / runtime fencing / no-payload-leak (tui-paste transport) -----------------------------------------------------------
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

# --- resume continuation bundle: embedded mission must be byte-exact -----------------------------------------------------------

# `$(cat file)` は末尾改行を無条件に落とすため、continuation bundle への
# mission 埋め込みで command substitution/関数の string 引数を経由すると、
# 複数の末尾改行や特殊文字を含む任意本文が byte-exact でなくなる。
NAME_RB="resume-bytes-t1"
MISSION_RB_FILE="$WORKROOT/mission-rb.txt"
printf 'line one\nspecial: $x \\ "quo'"'"'tes'"'"' `backtick` 日本語\nline two\n\n\n' >"$MISSION_RB_FILE"
RID1_RB=$(bash "$AGENTCTL" start --name "$NAME_RB" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY_OK" --mission-file "$MISSION_RB_FILE")
tmux kill-session -t "agentctl-$NAME_RB" >/dev/null 2>&1 || true
RID2_RB=$(bash "$AGENTCTL" resume --name "$NAME_RB" --cwd "$WORKROOT/worktree" --backend fake --from-runtime-id "$RID1_RB")
[ -n "$RID2_RB" ] || fail "resume (byte-exact test) did not produce a new runtime_id"

CONT_FILE_RB="$WORKROOT/state/agentctl/runtimes/$NAME_RB/continuation.txt"
if diff <(od -c "$MISSION_RB_FILE") <(sed -n '/^=== ORIGINAL MISSION ===$/,$p' "$CONT_FILE_RB" | tail -n +2 | od -c) >/tmp/agentctl-mission-bytes-diff; then
  pass "continuation bundle embeds the original mission byte-exact (multiple trailing newlines, special chars, multi-byte text preserved)"
else
  fail "continuation bundle mangled mission bytes: $(cat /tmp/agentctl-mission-bytes-diff)"
fi

bash "$AGENTCTL" stop --name "$NAME_RB" --runtime-id "$RID2_RB" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME_RB" --runtime-id "$RID2_RB" >/dev/null

if bash "$AGENTCTL" resume --name "$NAME_RS" --cwd "$WORKROOT/worktree" --backend fake --from-runtime-id "$RID1" 2>/tmp/agentctl-resume-err2; then
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

# --- codex operation-specific secure copy: TOCTOU/no-follow, bootstrap paste -----------------------------------------------------------

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

    # --- operation event log (metadata-only, no payload) -----------------------------------------------------------
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

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl unit tests passed."
else
  echo "Some agentctl unit tests FAILED."
fi
exit "$FAILED"
