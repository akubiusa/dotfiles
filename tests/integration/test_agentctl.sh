#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
#
# agentctl の real tmux integration テスト (plan Task 12)。
# tests/unit/test_agentctl.sh が検証する個々の内部不変条件 (fault-stage 単位の
# barrier、単一 runtime 内の byte-exact steer 等) を再検証するのではなく、
# 複数コマンドをまたぐ end-to-end シナリオを real tmux server 上で検証する。
# 実 Claude/Codex backend による live E2E (plan Task 13/14) は対象外。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping agentctl integration tests"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping agentctl integration tests"; exit 0; }

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
export TMPDIR="$WORKROOT/tmp"
mkdir -p "$TMPDIR"
unset TMUX || true

# unit test 用 (-L agentctl-test) とは別の tmux server を使い、並行実行時に
# セッション名が衝突しても互いに干渉しないようにする。
mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-integration-test "\$@"
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
POLICY="$WORKROOT/policy.json"
cat >"$POLICY" <<JSON
{"schema_version":1,"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false},"repository":{"git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}}
JSON

sink_path() { echo "$WORKROOT/state/agentctl/runtimes/$1/fake-sink.txt"; }
pane_pid_of() { bash "$AGENTCTL" status --name "$1" --json 2>/dev/null | jq -r '.runtime_id' >/dev/null; jq -r '.pane_pid' "$WORKROOT/state/agentctl/runtimes/$1/state.json"; }
reconcile_of() { bash "$AGENTCTL" status --name "$1" --json | jq -r '.reconcile'; }

# ============================================================
# シナリオ A: 大量 multiline 日本語 initial mission delivery + steer の
# byte-exact 転送
# (unit test は mission.txt が disk に保存されることまでしか見ていない。
#  ここでは v8 の核心である「start 時に backend プロセスへ mission 本文が
#  実際に届く」ことを fake-sink.txt への受信 evidence で検証する。steer
#  transport とは別の、独立した delivery 経路であることを区別して見る)
# ============================================================

NAME_A="int-large"
MISSION_LARGE=$(python3 -c "
lines = []
for i in range(200):
    lines.append(f'ミッション行 {i}: 日本語テキストとASCIIが混在する long mission body です。')
print('\n'.join(lines), end='')
")
echo -n "$MISSION_LARGE" >"$WORKROOT/mission-large.txt"

RID_A=$(bash "$AGENTCTL" start --name "$NAME_A" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-file "$WORKROOT/mission-large.txt")
sleep 0.5

MISSION_STORED="$WORKROOT/state/agentctl/runtimes/$NAME_A/mission.txt"
[ "$(cat "$MISSION_STORED")" = "$MISSION_LARGE" ] && pass "large multiline Japanese mission (200 lines) stored byte-exact" \
  || fail "large mission content mismatch"

# steer を一切呼ばない時点で、start だけで backend プロセスが mission 本文を
# 受信していることを確認する (これが mission delivery transport の evidence)。
if [ -f "$(sink_path "$NAME_A")" ] && [ "$(cat "$(sink_path "$NAME_A")")" = "$MISSION_LARGE" ]; then
  pass "large multiline Japanese initial mission (200 lines) delivered to backend at start, byte-exact, without manual Enter"
else
  fail "initial mission was not delivered to backend process: $(wc -c <"$(sink_path "$NAME_A")" 2>/dev/null || echo missing) bytes in sink"
fi

STEER_LARGE=$(python3 -c "
lines = []
for i in range(300):
    lines.append(f'ステア行 {i}: 特殊文字 \"quotes\" \`backticks\` \$(cmd) ; を含む。')
print('\n'.join(lines), end='')
")
echo -n "$STEER_LARGE" >"$WORKROOT/steer-large.txt"
bash "$AGENTCTL" steer --name "$NAME_A" --runtime-id "$RID_A" --file "$WORKROOT/steer-large.txt" >/dev/null
sleep 0.5

# sink は単一長命 fd への累積書き込みのため、steer 後は「mission + steer」と
# なるはず。mission delivery と steer delivery が同じ pty に対する 2 つの
# 独立した転送であることを、この連結で確認する。
EXPECTED_A="${MISSION_LARGE}${STEER_LARGE}"
if [ -f "$(sink_path "$NAME_A")" ] && [ "$(cat "$(sink_path "$NAME_A")")" = "$EXPECTED_A" ]; then
  pass "large multiline steer (300 lines, special chars) delivered byte-exact after mission, without manual Enter"
else
  fail "large steer payload mismatch or sink missing"
fi

bash "$AGENTCTL" stop --name "$NAME_A" --runtime-id "$RID_A" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME_A" --runtime-id "$RID_A" >/dev/null

# ============================================================
# シナリオ B: observer client の attach/detach が runtime に影響しない
# ============================================================

NAME_B="int-observer"
RID_B=$(bash "$AGENTCTL" start --name "$NAME_B" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"observer mission")
sleep 0.3
SESSION_B="agentctl-$NAME_B"

# control mode (-C) は tty を要求せず、script から観測者 client を模擬できる。
# stdin を /dev/null にすると即座に EOF で detach してしまうため、fifo を
# 開いたまま保持して observer client を「接続され続けている」状態にする。
OBSERVER_FIFO="$WORKROOT/observer.fifo"
mkfifo "$OBSERVER_FIFO"
exec 9<>"$OBSERVER_FIFO"
tmux -C attach-session -t "$SESSION_B" <&9 >"$WORKROOT/observer.out" 2>&1 &
OBSERVER_PID=$!
sleep 0.3

CLIENT_COUNT=$(tmux list-clients -t "$SESSION_B" 2>/dev/null | wc -l)
[ "$CLIENT_COUNT" -ge 1 ] && pass "observer client successfully attached to runtime session" \
  || fail "observer client failed to attach (client count=$CLIENT_COUNT)"

# observer を detach する (client process を終了させる = 実際の detach と同じ効果)。
kill "$OBSERVER_PID" 2>/dev/null || true
wait "$OBSERVER_PID" 2>/dev/null || true
exec 9>&-
rm -f "$OBSERVER_FIFO"
sleep 0.3

CLIENT_COUNT_AFTER=$(tmux list-clients -t "$SESSION_B" 2>/dev/null | wc -l)
[ "$CLIENT_COUNT_AFTER" -eq 0 ] && pass "observer client detached cleanly" \
  || fail "observer client still attached after kill (count=$CLIENT_COUNT_AFTER)"

RECONCILE_B=$(reconcile_of "$NAME_B")
[ "$RECONCILE_B" = "running" ] && pass "runtime remains running after observer detaches (no owner client dependency)" \
  || fail "runtime state affected by observer detach: reconcile=$RECONCILE_B"

# detach 後も steer が引き続き機能することを確認する
# (sink は start 時の initial mission delivery 分を既に含んでいる)。
echo -n "post-detach steer" >"$WORKROOT/steer-postdetach.txt"
bash "$AGENTCTL" steer --name "$NAME_B" --runtime-id "$RID_B" --file "$WORKROOT/steer-postdetach.txt" >/dev/null
sleep 0.3
EXPECTED_B=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME_B/mission.txt" "$WORKROOT/steer-postdetach.txt")
[ "$(cat "$(sink_path "$NAME_B")" 2>/dev/null)" = "$EXPECTED_B" ] \
  && pass "steer still works after observer detach" || fail "steer failed after observer detach"

bash "$AGENTCTL" stop --name "$NAME_B" --runtime-id "$RID_B" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME_B" --runtime-id "$RID_B" >/dev/null

# ============================================================
# シナリオ C: 複数 runtime を並列起動し、並列 steer が互いに漏れない
# (unit test の「単一 runtime 内の concurrent steer 順序保証」とは異なり、
#  ここでは runtime 間の isolation を検証する)
# ============================================================

NAMES_C=(int-par-1 int-par-2 int-par-3)
RIDS_C=()
for n in "${NAMES_C[@]}"; do
  rid=$(bash "$AGENTCTL" start --name "$n" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"parallel mission $n")
  RIDS_C+=("$rid")
done
sleep 0.3

pids=()
i=0
for n in "${NAMES_C[@]}"; do
  echo -n "payload-for-$n" >"$WORKROOT/steer-$n.txt"
  bash "$AGENTCTL" steer --name "$n" --runtime-id "${RIDS_C[$i]}" --file "$WORKROOT/steer-$n.txt" >/dev/null &
  pids+=($!)
  i=$((i + 1))
done
for p in "${pids[@]}"; do wait "$p"; done
sleep 0.5

CROSSTALK=0
for n in "${NAMES_C[@]}"; do
  got=$(cat "$(sink_path "$n")" 2>/dev/null || echo "MISSING")
  expected=$(cat "$WORKROOT/state/agentctl/runtimes/$n/mission.txt" "$WORKROOT/steer-$n.txt")
  if [ "$got" != "$expected" ]; then
    fail "runtime '$n' received wrong/missing payload: got '$got'"
    CROSSTALK=1
  fi
done
[ "$CROSSTALK" -eq 0 ] && pass "parallel runtimes receive only their own initial mission + steer payload (no cross-runtime leakage)"

for i in "${!NAMES_C[@]}"; do
  bash "$AGENTCTL" stop --name "${NAMES_C[$i]}" --runtime-id "${RIDS_C[$i]}" >/dev/null
  bash "$AGENTCTL" cleanup --name "${NAMES_C[$i]}" --runtime-id "${RIDS_C[$i]}" >/dev/null
done

# ============================================================
# シナリオ D: real crash recovery lifecycle
# (env var fault-injection ではなく実プロセス kill -9 による crash を模擬し、
#  publication barrier -> reconcile -> resume -> complete -> cleanup を
#  1本の継続シナリオとして end-to-end で検証する)
# ============================================================

NAME_D="int-lifecycle"
RID1_D=$(bash "$AGENTCTL" start --name "$NAME_D" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"lifecycle mission")
sleep 0.3
echo -n "checkpoint-before-crash" >"$WORKROOT/steer-checkpoint.txt"
bash "$AGENTCTL" steer --name "$NAME_D" --runtime-id "$RID1_D" --file "$WORKROOT/steer-checkpoint.txt" >/dev/null
sleep 0.3
EXPECTED_D_PRECRASH=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME_D/mission.txt" "$WORKROOT/steer-checkpoint.txt")
[ "$(cat "$(sink_path "$NAME_D")" 2>/dev/null)" = "$EXPECTED_D_PRECRASH" ] \
  && pass "lifecycle: pre-crash steer delivered after initial mission" || fail "lifecycle: pre-crash steer missing"

BACKEND_PID=$(jq -r '.pane_pid' "$WORKROOT/state/agentctl/runtimes/$NAME_D/state.json")
kill -9 "$BACKEND_PID" 2>/dev/null || true
sleep 0.5

RECONCILE_CRASHED=$(reconcile_of "$NAME_D")
[ "$RECONCILE_CRASHED" = "exited" ] && pass "lifecycle: real backend process kill is reconciled as exited (remain-on-exit captures the crash)" \
  || fail "lifecycle: expected reconcile=exited after real crash, got '$RECONCILE_CRASHED'"

RID2_D=$(bash "$AGENTCTL" resume --name "$NAME_D" --cwd "$WORKROOT/worktree" --backend fake --from-runtime-id "$RID1_D")
[ -n "$RID2_D" ] && [ "$RID2_D" != "$RID1_D" ] && pass "lifecycle: resume publishes a fresh generation after real crash" \
  || fail "lifecycle: resume did not produce a new runtime_id"

MISSION_AFTER_RESUME=$(cat "$WORKROOT/state/agentctl/runtimes/$NAME_D/mission.txt")
[ "$MISSION_AFTER_RESUME" = "lifecycle mission" ] && pass "lifecycle: resume reuses the original mission.txt unchanged" \
  || fail "lifecycle: mission.txt was altered by resume"

sleep 0.5
# resume は respawn-pane で新しい backend プロセス (フレッシュな sink) を作るため、
# 前世代の checkpoint-before-crash は引き継がれない。resume 直後、steer を呼ぶ前に、
# 前世代 manifest/log/policy と元の mission 本文を束ねた read-only continuation
# bundle が、単一 turn として fresh backend に実際に届いていることを確認する
# (manifest を検証するだけで済ませず、fresh backend が実際に continuation
# context を受け取ることが v8 spec の要件)。paste+screen-settle には turn 完了
# を確認する barrier が無いため、continuation context と mission 本文は 2 turn
# に分けず 1 ファイル・1 turn として届ける (2 turn に分けると 1 turn 目実行中の
# steer と区別できず実 backend 上で衝突し得るため)。
CONT_FILE_D="$WORKROOT/state/agentctl/runtimes/$NAME_D/continuation.txt"
[ -f "$CONT_FILE_D" ] && pass "lifecycle: resume writes a continuation bundle for the fresh generation" \
  || fail "lifecycle: resume did not write a continuation bundle"
[ "$(cat "$(sink_path "$NAME_D")" 2>/dev/null)" = "$(cat "$CONT_FILE_D")" ] \
  && pass "lifecycle: resume delivers the continuation bundle (embedding the original mission) as a single atomic turn" \
  || fail "lifecycle: resume did not deliver the continuation bundle as a single turn to the fresh backend sink"

sleep 0.3
echo -n "checkpoint-after-resume" >"$WORKROOT/steer-after-resume.txt"
bash "$AGENTCTL" steer --name "$NAME_D" --runtime-id "$RID2_D" --file "$WORKROOT/steer-after-resume.txt" >/dev/null
sleep 0.3
EXPECTED_D_POSTRESUME=$(cat "$CONT_FILE_D" "$WORKROOT/steer-after-resume.txt")
[ "$(cat "$(sink_path "$NAME_D")" 2>/dev/null)" = "$EXPECTED_D_POSTRESUME" ] \
  && pass "lifecycle: post-resume generation accepts steer after the continuation bundle (no stale checkpoint leaked from crashed generation)" \
  || fail "lifecycle: post-resume steer failed or delivered to stale sink"

bash "$AGENTCTL" stop --name "$NAME_D" --runtime-id "$RID2_D" >/dev/null

MANIFEST_D="$WORKROOT/state/agentctl/runtimes/$NAME_D/manifest.json"
jq '.mission_status = "done"' "$MANIFEST_D" >"$MANIFEST_D.tmp" && mv "$MANIFEST_D.tmp" "$MANIFEST_D"
bash "$AGENTCTL" complete --name "$NAME_D" --runtime-id "$RID2_D" >/dev/null \
  && pass "lifecycle: complete succeeds once continuation manifest reports done" \
  || fail "lifecycle: complete failed on a done manifest"

bash "$AGENTCTL" cleanup --name "$NAME_D" --runtime-id "$RID2_D" >/dev/null \
  && pass "lifecycle: cleanup succeeds after complete (no Git integration required)" \
  || fail "lifecycle: cleanup failed after complete"

RECONCILE_FINAL=$(reconcile_of "$NAME_D")
[ "$RECONCILE_FINAL" = "absent" ] && pass "lifecycle: runtime fully torn down at the end of start->crash->resume->complete->cleanup" \
  || fail "lifecycle: runtime not fully torn down, reconcile=$RECONCILE_FINAL"

# ============================================================
# シナリオ E: logs / attach (real tmux client) / interrupt
# (unit test は fencing 拒否パスのみ検証する。ここでは実 tmux client の
# attach/detach、logs による pane evidence 取得、interrupt 後の
# reconcile/再操作を real tmux server 上で検証する)
# ============================================================

NAME_E="int-logs-attach"
RID_E=$(bash "$AGENTCTL" start --name "$NAME_E" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"logs attach mission marker")
sleep 0.3
SESSION_E="agentctl-$NAME_E"

LOGS_E=$(bash "$AGENTCTL" logs --name "$NAME_E")
echo "$LOGS_E" | grep -q "logs attach mission marker" \
  && pass "logs returns real pane evidence containing the delivered mission" \
  || fail "logs did not contain expected mission marker: $LOGS_E"

# agentctl attach 内部の `tmux attach-session` (非 control-mode) は本物の
# terminal を要求するため、`script -qc` で pty を割り当てて CLI コマンド
# そのものを実行し、実 client が接続されることを検証する。
script -qc "bash '$AGENTCTL' attach --name '$NAME_E' --runtime-id '$RID_E'" /dev/null \
  >"$WORKROOT/attach-cli.out" 2>&1 &
sleep 0.7

CLIENT_COUNT_E=$(tmux list-clients -t "$SESSION_E" 2>/dev/null | wc -l)
[ "$CLIENT_COUNT_E" -ge 1 ] && pass "'agentctl attach' connects a real tmux client to the owned session" \
  || fail "'agentctl attach' did not connect a client: $(cat "$WORKROOT/attach-cli.out")"

# script/agentctl 自体を kill しても、その先の real tmux client 子プロセスが
# orphan 化して attach したまま残るため、実 tmux プロセスを直接狙って kill する。
pkill -f "attach-session -t $SESSION_E" 2>/dev/null || true
sleep 0.5

RECONCILE_E_AFTER_ATTACH=$(reconcile_of "$NAME_E")
[ "$RECONCILE_E_AFTER_ATTACH" = "running" ] && pass "runtime remains running after attached client disconnects" \
  || fail "runtime state affected by attach client disconnect: reconcile=$RECONCILE_E_AFTER_ATTACH"

# interrupt: pane/runtime を破壊せず Ctrl-C keystroke を送るだけであること。
INTERRUPT_E=$(bash "$AGENTCTL" interrupt --name "$NAME_E" --runtime-id "$RID_E")
[ "$INTERRUPT_E" = "interrupted" ] && pass "interrupt delivered to the owned runtime" \
  || fail "interrupt failed: $INTERRUPT_E"
sleep 0.3
RECONCILE_E_AFTER_INTERRUPT=$(reconcile_of "$NAME_E")
[ "$RECONCILE_E_AFTER_INTERRUPT" = "running" ] && pass "runtime remains running after interrupt (no destructive kill)" \
  || fail "runtime not running after interrupt: reconcile=$RECONCILE_E_AFTER_INTERRUPT"

# interrupt 後も steer/logs による再操作が引き続き機能すること。
echo -n "post-interrupt-check" >"$WORKROOT/steer-post-interrupt-e.txt"
bash "$AGENTCTL" steer --name "$NAME_E" --runtime-id "$RID_E" --file "$WORKROOT/steer-post-interrupt-e.txt" >/dev/null
sleep 0.3
[ "$(cat "$(sink_path "$NAME_E")" 2>/dev/null | grep -c "post-interrupt-check")" -ge 1 ] \
  && pass "steer still works after interrupt" || fail "steer after interrupt failed"

LOGS_E_AFTER=$(bash "$AGENTCTL" logs --name "$NAME_E" --lines 100)
echo "$LOGS_E_AFTER" | grep -q "post-interrupt-check" \
  && pass "logs reflects state after interrupt + steer re-operation" \
  || fail "logs after interrupt/steer missing expected content"

# fencing: 古い runtime-id での attach/interrupt は拒否される。
if bash "$AGENTCTL" interrupt --name "$NAME_E" --runtime-id "00000000-0000-0000-0000-000000000000" 2>/dev/null; then
  fail "interrupt with stale runtime-id must be rejected"
else
  pass "interrupt with stale runtime-id is rejected"
fi

bash "$AGENTCTL" stop --name "$NAME_E" --runtime-id "$RID_E" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME_E" --runtime-id "$RID_E" >/dev/null

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl integration tests passed."
else
  echo "Some agentctl integration tests FAILED."
fi
exit "$FAILED"
