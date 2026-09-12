#!/bin/bash
# shellcheck disable=SC2015,SC2329,SC2317
# SC2317: trap/mock 経由で間接実行する関数本体を旧ShellCheckが到達不能と誤検知する。
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
# agentctl-deployment-preflight の read-only 判定テスト。
# 稼働中 runtime が無ければ exit 0、あれば exit 1 で拒否し、
# runtime 自体には一切手を触れない (stop/kill しない) ことを検証する。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"
PREFLIGHT="$REPO_ROOT/home/bin/executable_agentctl-deployment-preflight"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping preflight tests"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping preflight tests"; exit 0; }

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-preflight-test "\$@"
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
{"version":1,"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false},"scope":{"repositories":[{"id":"primary","git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}],"remotes":[],"production_targets":[]}}
JSON

if bash "$PREFLIGHT" >/tmp/agentctl-preflight-out 2>&1; then
  pass "preflight allows rollback when no runtimes exist"
else
  fail "preflight should succeed with no runtimes: $(cat /tmp/agentctl-preflight-out)"
fi

RID=$(bash "$AGENTCTL" start --name pf1 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission")

if bash "$PREFLIGHT" >/tmp/agentctl-preflight-out2 2>&1; then
  fail "preflight should refuse rollback while runtime pf1 is running"
else
  grep -q "pf1" /tmp/agentctl-preflight-out2 && pass "preflight refuses rollback and names the blocking runtime" \
    || fail "preflight rejection did not name blocking runtime: $(cat /tmp/agentctl-preflight-out2)"
fi

RECONCILE_AFTER=$(bash "$AGENTCTL" status --name pf1 --json | jq -r '.reconcile')
[ "$RECONCILE_AFTER" = "running" ] && pass "preflight is read-only: runtime pf1 still running after refusal" \
  || fail "preflight must never stop/kill runtimes, but reconcile=$RECONCILE_AFTER"

bash "$AGENTCTL" stop --name pf1 --runtime-id "$RID" >/dev/null
bash "$AGENTCTL" cleanup --name pf1 --runtime-id "$RID" >/dev/null 2>&1 || true

# --- rollback interlock は inventory -> removal/apply -> postcheck を一操作として覆う ---

MARKER="$WORKROOT/rollback-ran"
if bash "$PREFLIGHT" -- touch "$MARKER" >/tmp/agentctl-preflight-wrap-out 2>&1; then
  [ -f "$MARKER" ] && pass "preflight with a wrapped command runs it after confirming no active runtimes" \
    || fail "preflight wrap mode reported success but the wrapped command never ran"
else
  fail "preflight wrap mode should succeed with no runtimes: $(cat /tmp/agentctl-preflight-wrap-out)"
fi
rm -f "$MARKER"

RID2=$(bash "$AGENTCTL" start --name pf2 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission2")
if bash "$PREFLIGHT" -- touch "$MARKER" >/tmp/agentctl-preflight-wrap-out2 2>&1; then
  fail "preflight wrap mode should refuse to run the rollback command while pf2 is running"
else
  [ ! -f "$MARKER" ] && grep -q "pf2" /tmp/agentctl-preflight-wrap-out2 \
    && pass "preflight wrap mode never runs the rollback command when an active runtime blocks it" \
    || fail "preflight wrap mode ran the command (or omitted the blocker name) despite pf2 running"
fi
RECONCILE_PF2=$(bash "$AGENTCTL" status --name pf2 --json | jq -r '.reconcile')
[ "$RECONCILE_PF2" = "running" ] && pass "rollback interlock never auto-kills the blocking runtime" \
  || fail "pf2 should remain running after a refused rollback, but reconcile=$RECONCILE_PF2"
bash "$AGENTCTL" stop --name pf2 --runtime-id "$RID2" >/dev/null
bash "$AGENTCTL" cleanup --name pf2 --runtime-id "$RID2" >/dev/null 2>&1 || true

# rollback の exclusive section が長時間実行中でも、並行 start は shared lock で待機し、
# exclusive section 解放前に generation を publish できないことを確認する。
ROLLBACK_LOG="$WORKROOT/rollback.log"
: >"$ROLLBACK_LOG"
bash "$PREFLIGHT" -- bash -c 'echo begin >>'"$ROLLBACK_LOG"'; sleep 2; echo end >>'"$ROLLBACK_LOG"'' &
PREFLIGHT_PID=$!
# 上の preflight が exclusive lock を確実に取得してから start を投げる。
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q begin "$ROLLBACK_LOG" 2>/dev/null && break
  sleep 0.2
done

START_BEGIN=$(date +%s.%N)
RID3=$(bash "$AGENTCTL" start --name pf3 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission3")
START_END=$(date +%s.%N)
wait "$PREFLIGHT_PID"

START_DURATION=$(awk -v b="$START_BEGIN" -v e="$START_END" 'BEGIN{print e-b}')
awk -v d="$START_DURATION" 'BEGIN{exit !(d>=1.0)}' \
  && pass "concurrent 'start' blocks on the shared lock while the rollback exclusive section is active" \
  || fail "concurrent 'start' returned in ${START_DURATION}s without waiting for the rollback exclusive section"
[ -n "$RID3" ] && pass "start still publishes successfully once the rollback exclusive section releases" \
  || fail "start did not publish a runtime_id after the rollback exclusive section released"
bash "$AGENTCTL" stop --name pf3 --runtime-id "$RID3" >/dev/null
bash "$AGENTCTL" cleanup --name pf3 --runtime-id "$RID3" >/dev/null 2>&1 || true

# 同じ barrier を resume にも適用し、stopped/exited runtime が rollback 中に
# fresh generation を publish できないことを確認する。
RID4=$(bash "$AGENTCTL" start --name pf4 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission4")
bash "$AGENTCTL" stop --name pf4 --runtime-id "$RID4" >/dev/null
tmux kill-session -t "agentctl-pf4" >/dev/null 2>&1 || true

: >"$ROLLBACK_LOG"
bash "$PREFLIGHT" -- bash -c 'echo begin >>'"$ROLLBACK_LOG"'; sleep 2; echo end >>'"$ROLLBACK_LOG"'' &
PREFLIGHT_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q begin "$ROLLBACK_LOG" 2>/dev/null && break
  sleep 0.2
done

RESUME_BEGIN=$(date +%s.%N)
RID4B=$(bash "$AGENTCTL" resume --name pf4 --from-runtime-id "$RID4")
RESUME_END=$(date +%s.%N)
wait "$PREFLIGHT_PID"

RESUME_DURATION=$(awk -v b="$RESUME_BEGIN" -v e="$RESUME_END" 'BEGIN{print e-b}')
awk -v d="$RESUME_DURATION" 'BEGIN{exit !(d>=1.0)}' \
  && pass "concurrent 'resume' blocks on the shared lock while the rollback exclusive section is active" \
  || fail "concurrent 'resume' returned in ${RESUME_DURATION}s without waiting for the rollback exclusive section"
[ -n "$RID4B" ] && pass "resume still publishes successfully once the rollback exclusive section releases" \
  || fail "resume did not publish a runtime_id after the rollback exclusive section released"
bash "$AGENTCTL" stop --name pf4 --runtime-id "$RID4B" >/dev/null
bash "$AGENTCTL" cleanup --name pf4 --runtime-id "$RID4B" >/dev/null 2>&1 || true

# --- rollback後の guard removal/breakageを fail closed にする検証 ---
# --- Codex guard wiring破損後は start/resume の publish を拒否する検証 ---
# guard preflight は respawn-pane より前の _publish_generation 内で同期的に
# 走り、失敗時はそこで die するため、guard 破壊後の start/resume には実 codex
# バイナリは不要。resume は predecessor から backend を厳密に継承する
# (--backend override を受け付けない) ため、predecessor の state.json に
# backend=codex を記録させる必要があるが、実 codex CLI を respawn-pane 経由で
# 起動して guard-sentinel handshake を完走させることはこの unit test の
# 対象外 (real Codex 実プロセスでの live guard 検証は別の統合テストが担う)。
# そのため backend=fake で無害に start してから、state.json の backend
# フィールドだけを codex へ書き換える fixture 手法を使う。
CODEX_HOME="$WORKROOT/codex-home"
mkdir -p "$CODEX_HOME/.codex/hooks"
jq -n '{hooks:{PreToolUse:[{matcher:"^Bash$",hooks:[{type:"command",command:"bash ~/.codex/hooks/agentctl-policy-dispatcher.sh"}]}]}}' \
  >"$CODEX_HOME/.codex/hooks.json"
cp "$REPO_ROOT/home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh" "$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh"

RIDCX=$(HOME="$CODEX_HOME" bash "$AGENTCTL" start --name pfcx --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"missioncx")
bash "$AGENTCTL" stop --name pfcx --runtime-id "$RIDCX" >/dev/null
tmux kill-session -t "agentctl-pfcx" >/dev/null 2>&1 || true
STATE_PFCX="$WORKROOT/state/agentctl/runtimes/pfcx/state.json"
jq '.backend = "codex"' "$STATE_PFCX" >"$STATE_PFCX.tmp" && mv "$STATE_PFCX.tmp" "$STATE_PFCX"

# rollback: dispatcher の委譲先を壊す (= 依存の削除/バージョン不一致を模す)。
bash "$PREFLIGHT" -- bash -c "echo 'source \"\$HOME/bin/does-not-exist.sh\"' > '$CODEX_HOME/.codex/hooks/agentctl-policy-dispatcher.sh'" \
  >/tmp/agentctl-preflight-rollback-codex-out 2>&1
RC=$?
[ "$RC" -eq 0 ] && pass "rollback wrap mode successfully applies the (guard-breaking) removal command" \
  || fail "rollback wrap mode should succeed applying the removal command: $(cat /tmp/agentctl-preflight-rollback-codex-out)"

if HOME="$CODEX_HOME" bash "$AGENTCTL" start --name pfcx2 --cwd "$WORKROOT/worktree" --backend codex --policy-file "$POLICY" --mission-stdin <<<"missioncx2" \
  >/tmp/agentctl-postremoval-start-out 2>/tmp/agentctl-postremoval-start-err; then
  fail "start should fail closed after guard wiring was broken by the rollback"
else
  grep -q "guard preflight failed" /tmp/agentctl-postremoval-start-err \
    && pass "start fails closed after post-rollback guard wiring is broken (no publish)" \
    || fail "start failed for the wrong reason: $(cat /tmp/agentctl-postremoval-start-err)"
fi
[ ! -e "$WORKROOT/state/agentctl/runtimes/pfcx2/state.json" ] \
  && pass "start does not publish any state for pfcx2 after the fail-closed guard preflight" \
  || fail "start left behind a published state.json despite the fail-closed guard preflight"
TMUX_SESSIONS_AFTER=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^agentctl-pfcx2$' || true)
[ "$TMUX_SESSIONS_AFTER" -eq 0 ] \
  && pass "start leaves no tmux session behind for pfcx2 after the fail-closed guard preflight" \
  || fail "start left a tmux session behind for pfcx2 despite the fail-closed guard preflight"

if HOME="$CODEX_HOME" bash "$AGENTCTL" resume --name pfcx --from-runtime-id "$RIDCX" \
  >/tmp/agentctl-postremoval-resume-out 2>/tmp/agentctl-postremoval-resume-err; then
  fail "resume should fail closed after guard wiring was broken by the rollback"
else
  grep -q "guard preflight failed" /tmp/agentctl-postremoval-resume-err \
    && pass "resume fails closed after post-rollback guard wiring is broken (no fresh generation published)" \
    || fail "resume failed for the wrong reason: $(cat /tmp/agentctl-postremoval-resume-err)"
fi
RESUME_STATE_RID=$(jq -r '.runtime_id' "$WORKROOT/state/agentctl/runtimes/pfcx/state.json" 2>/dev/null || echo "")
[ "$RESUME_STATE_RID" = "$RIDCX" ] \
  && pass "resume's fail-closed guard preflight leaves the predecessor generation's state untouched" \
  || fail "resume mutated pfcx's state despite the fail-closed guard preflight (runtime_id=$RESUME_STATE_RID, expected $RIDCX)"

tmux kill-session -t "agentctl-pfcx" >/dev/null 2>&1 || true
tmux kill-session -t "agentctl-pfcx2" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/pfcx" "$WORKROOT/state/agentctl/runtimes/pfcx2"

# --- 経過時間ではなく file existence で判定する deterministic barrier race 検証 ---
# AGENTCTL_TEST_BARRIER_STAGE=post_lock_pre_preflight は _publish_generation が
# shared lock を取得した直後、guard/backend preflight の直前で処理を止める。
# これにより「generation creation が preflight に入った/入る直前で止まっている
# 間、exclusive rollback は絶対に通過できない」ことを経過時間ではなく
# ファイルの有無で決定的に証明できる。

REACHED5="$WORKROOT/pf5-reached"
RESUME5="$WORKROOT/pf5-resume"
MARKER5="$WORKROOT/pf5-rollback-marker"
rm -f "$REACHED5" "$RESUME5" "$MARKER5"

AGENTCTL_TEST_BARRIER_STAGE=post_lock_pre_preflight \
AGENTCTL_TEST_BARRIER_REACHED_FILE="$REACHED5" \
AGENTCTL_TEST_BARRIER_RESUME_FILE="$RESUME5" \
  bash "$AGENTCTL" start --name pf5 --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission5" \
  >"$WORKROOT/pf5-start-out" &
START5_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$REACHED5" ] && break
  sleep 0.2
done
[ -e "$REACHED5" ] || fail "start did not reach the post_lock_pre_preflight barrier within the timeout"

bash "$PREFLIGHT" -- touch "$MARKER5" >"$WORKROOT/pf5-rollback-out" 2>&1 &
ROLLBACK5_PID=$!

# start が shared lock を保持したまま barrier で止まっている間、rollback の
# exclusive lock 取得は flock で必ずブロックされる。経過時間ではなく
# マーカー未生成であることそのものを決定的な証拠として使う。
for _ in 1 2 3 4 5; do
  sleep 0.2
  [ -e "$MARKER5" ] && break
done
[ ! -e "$MARKER5" ] && pass "exclusive rollback cannot pass while a creation is paused inside the locked preflight section" \
  || fail "exclusive rollback ran while a creation still held the shared lock inside preflight"

: >"$RESUME5"
wait "$START5_PID"
RID5=$(cat "$WORKROOT/pf5-start-out")
wait "$ROLLBACK5_PID"

[ -n "$RID5" ] && pass "the paused creation completes publication once released from the barrier" \
  || fail "start did not publish a runtime_id after the barrier was released: $(cat "$WORKROOT/pf5-start-out")"
# rollback の flock 自体は creation の shared lock 解放と同時に解ける。その後は
# 通常の inventory check (allow-list) が働き、publish 完了した pf5 は running
# として正しく検出され rollback を再度拒否する (自動 kill は絶対にしない)。
[ ! -e "$MARKER5" ] && grep -q "pf5" "$WORKROOT/pf5-rollback-out" \
  && pass "once unblocked, rollback correctly re-refuses because the just-published pf5 is now running" \
  || fail "rollback should be unblocked by the lock release but still refused by the inventory check for pf5: $(cat "$WORKROOT/pf5-rollback-out")"
bash "$AGENTCTL" stop --name pf5 --runtime-id "$RID5" >/dev/null 2>&1 || true
bash "$AGENTCTL" cleanup --name pf5 --runtime-id "$RID5" >/dev/null 2>&1 || true

# 逆方向: rollback が exclusive lock を保持したまま guard を破壊している間に
# 割り込んできた creation は、rollback 完了後に shared lock を取得して
# 初めて preflight を実行する。stale (rollback 前) の preflight 判定を
# 使い回すのではなく、post-removal の世界に対して preflight を再実行して
# fail closed することを、経過時間ではなく到達ファイルの有無で証明する。

CODEX_HOME2="$WORKROOT/codex-home2"
mkdir -p "$CODEX_HOME2/.codex/hooks"
jq -n '{hooks:{PreToolUse:[{matcher:"^Bash$",hooks:[{type:"command",command:"bash ~/.codex/hooks/agentctl-policy-dispatcher.sh"}]}]}}' \
  >"$CODEX_HOME2/.codex/hooks.json"
cp "$REPO_ROOT/home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh" "$CODEX_HOME2/.codex/hooks/agentctl-policy-dispatcher.sh"

REACHED_RB="$WORKROOT/rollback-reached"
RESUME_RB="$WORKROOT/rollback-resume"
rm -f "$REACHED_RB" "$RESUME_RB"

bash "$PREFLIGHT" -- bash -c \
  ": >'$REACHED_RB'; while [ ! -e '$RESUME_RB' ]; do sleep 0.05; done; echo 'source \"\$HOME/bin/does-not-exist.sh\"' > '$CODEX_HOME2/.codex/hooks/agentctl-policy-dispatcher.sh'" \
  >"$WORKROOT/rollback2-out" 2>&1 &
ROLLBACK2_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$REACHED_RB" ] && break
  sleep 0.2
done
[ -e "$REACHED_RB" ] || fail "rollback did not reach its exclusive-hold barrier within the timeout"

HOME="$CODEX_HOME2" bash "$AGENTCTL" start --name pfcx3 --cwd "$WORKROOT/worktree" --backend codex --policy-file "$POLICY" --mission-stdin <<<"missioncx3" \
  >"$WORKROOT/pfcx3-start-out" 2>"$WORKROOT/pfcx3-start-err" &
START_CX3_PID=$!

# creation は rollback が保持する exclusive lock の裏で shared lock 待ちの
# はずなので、rollback がまだ guard を破壊し終える前は state.json が
# 存在しないことを決定的に確認する (経過時間ではなくファイルの有無)。
for _ in 1 2 3 4 5; do
  sleep 0.2
  [ -e "$WORKROOT/state/agentctl/runtimes/pfcx3/state.json" ] && break
done
[ ! -e "$WORKROOT/state/agentctl/runtimes/pfcx3/state.json" ] \
  && pass "a creation blocked behind rollback does not publish before the exclusive section ends" \
  || fail "a creation blocked behind rollback published state before the rollback's exclusive section ended"

: >"$RESUME_RB"
wait "$ROLLBACK2_PID"
wait "$START_CX3_PID"
START_CX3_STATUS=$?

if [ "$START_CX3_STATUS" -eq 0 ]; then
  fail "creation blocked behind rollback should fail closed once the guard was removed, but it succeeded"
else
  grep -q "guard preflight failed" "$WORKROOT/pfcx3-start-err" \
    && pass "a creation blocked behind rollback re-runs guard preflight after removal and fails closed" \
    || fail "creation failed for the wrong reason: $(cat "$WORKROOT/pfcx3-start-err")"
fi
[ ! -e "$WORKROOT/state/agentctl/runtimes/pfcx3/state.json" ] \
  && pass "the blocked-then-failed creation never publishes state for pfcx3" \
  || fail "pfcx3 state.json was published despite the post-removal fail-closed guard preflight"
tmux kill-session -t "agentctl-pfcx3" >/dev/null 2>&1 || true
rm -rf "$WORKROOT/state/agentctl/runtimes/pfcx3"

# --- 前世代の close-on-exec 対策が wrapped rollback command にも及ぶこと ---------

# bash の {fd} 自動割当は close-on-exec が立たない (agentctl_tmux() が同じ
# 理由で対策済み)。wrapped command 自身が daemonize する子を残して先に
# 戻った場合、その子が lock fd を継承していれば、preflight 側が release
# した後もこの独立子プロセスが flock を握り続けてしまう。
FDTEST_LOCKFILE="$WORKROOT/state/agentctl/locks/deployment.lock"
FDTEST_CHILD_MARKER="$WORKROOT/fd-inherit-child-marker"
rm -f "$FDTEST_CHILD_MARKER"

bash "$PREFLIGHT" -- bash -c '
  ( sleep 8 ) &
  disown
  touch "'"$FDTEST_CHILD_MARKER"'"
' >/dev/null 2>&1
FDTEST_PREFLIGHT_RC=$?

if [ "$FDTEST_PREFLIGHT_RC" -eq 0 ] && [ -f "$FDTEST_CHILD_MARKER" ]; then
  if flock -n "$FDTEST_LOCKFILE" -c 'true'; then
    pass "deployment lock is not held by a daemonizing rollback-command child after preflight exits (lock fd closed before exec)"
  else
    fail "deployment lock is still held after preflight exited: a daemonizing rollback command child inherited the lock fd"
  fi
else
  fail "fd-inheritance test setup failed: preflight rc=$FDTEST_PREFLIGHT_RC marker_present=$([ -f "$FDTEST_CHILD_MARKER" ] && echo yes || echo no)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-deployment-preflight unit tests passed."
else
  echo "Some agentctl-deployment-preflight unit tests FAILED."
fi
exit "$FAILED"
