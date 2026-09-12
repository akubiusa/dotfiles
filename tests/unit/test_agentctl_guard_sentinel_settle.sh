#!/bin/bash
# shellcheck disable=SC2015,SC2329,SC2317
# SC2317: trap/mock 経由で間接実行する関数本体を旧ShellCheckが到達不能と誤検知する。
# SC2015: `check && pass || fail` は本テストの意図通り。
# agentctl_verify_guard_sentinel (agentctl-common.sh) の post-evidence settle
# barrier テスト。dispatcher が guard-sentinel.json を書く時点は、backend が
# その deny 結果を画面へ描画し終えるタイミングとは限らない。evidence 確認直後に
# 次の mission delivery の paste-buffer を送ると、sentinel turn がまだ描画中の
# 画面に mission が割り込む race が起こり得るため、evidence 確認後にもう一段
# screen-settle を待つことを検証する (実 Claude/Codex を使わず、tmux pane を
# 制御可能な fake script で代替した function-level テスト)。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping guard sentinel settle tests"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping guard sentinel settle tests"; exit 0; }

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

WORKROOT=$(mktemp -d)
TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR" "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-sentinel-settle-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export TMUX_TMPDIR PATH="$WORKROOT/bin:$PATH"
unset TMUX || true
trap 'tmux kill-server >/dev/null 2>&1 || true; rm -rf "$WORKROOT"' EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/home/bin/agentctl-common.sh"

RUNTIME_ID="rtsettle1"
DIR="$WORKROOT/runtime"
mkdir -p "$DIR"

# --- 成功系: evidence 出現後もしばらく画面が変化し続け、その後静止する pane -----------------------------------------------------------
cat >"$WORKROOT/fake-settling-backend.sh" <<SCRIPT
#!/bin/bash
read -r _line
jq -n --arg runtime_id "$RUNTIME_ID" '{runtime_id:\$runtime_id, decision:"deny"}' >"$DIR/guard-sentinel.json"
for i in 1 2 3 4 5 6; do echo "rendering-frame-\$i"; sleep 0.5; done
echo "settled-marker"
sleep 60
SCRIPT
chmod +x "$WORKROOT/fake-settling-backend.sh"

tmux new-session -d -s settletest1 -c "$WORKROOT" "$WORKROOT/fake-settling-backend.sh"
PANE1=$(tmux display-message -p -t settletest1 '#{pane_id}')

START=$(date +%s)
if agentctl_verify_guard_sentinel fake "$PANE1" "$DIR" "$RUNTIME_ID"; then
  END=$(date +%s)
  ELAPSED=$((END - START))
  # rendering (3s) + quiet_duration (2s) 分は必ず待たされるはず。evidence 出現
  # 直後に即 return していた旧実装なら 1s 未満で返る。
  [ "$ELAPSED" -ge 4 ] \
    && pass "agentctl_verify_guard_sentinel waits for the pane to settle after evidence appears (elapsed=${ELAPSED}s)" \
    || fail "agentctl_verify_guard_sentinel returned too quickly after evidence appeared (elapsed=${ELAPSED}s, expected >=4s)"
else
  fail "agentctl_verify_guard_sentinel unexpectedly failed for a pane that settles normally"
fi
tmux kill-session -t settletest1 >/dev/null 2>&1 || true

# --- 失敗系: evidence 出現後、画面が静止しないまま settle timeout に達する -----------------------------------------------------------
RUNTIME_ID2="rtsettle2"
DIR2="$WORKROOT/runtime2"
mkdir -p "$DIR2"
cat >"$WORKROOT/fake-neverquiet-backend.sh" <<SCRIPT
#!/bin/bash
read -r _line
jq -n --arg runtime_id "$RUNTIME_ID2" '{runtime_id:\$runtime_id, decision:"deny"}' >"$DIR2/guard-sentinel.json"
while true; do echo "still-rendering-\$RANDOM"; sleep 0.2; done
SCRIPT
chmod +x "$WORKROOT/fake-neverquiet-backend.sh"

tmux new-session -d -s settletest2 -c "$WORKROOT" "$WORKROOT/fake-neverquiet-backend.sh"
PANE2=$(tmux display-message -p -t settletest2 '#{pane_id}')

if AGENTCTL_SENTINEL_SETTLE_TIMEOUT_SECONDS=2 agentctl_verify_guard_sentinel fake "$PANE2" "$DIR2" "$RUNTIME_ID2"; then
  fail "agentctl_verify_guard_sentinel should fail closed when the pane never settles after evidence appears"
else
  [ -f "$DIR2/guard-sentinel.json" ] \
    && pass "agentctl_verify_guard_sentinel fails closed on settle timeout even though evidence itself was written (proves the timeout is the new settle wait, not a missing-evidence failure)" \
    || fail "expected evidence file to exist even on settle-timeout failure"
fi
tmux kill-session -t settletest2 >/dev/null 2>&1 || true

# --- Codex: sentinel marker must be present in the first prompt itself 検証 ------------------
# Codex runtime は分類不能な exec call を拒否するため、sentinel を operation-file の背後へ
# 隠すと marker 到達前の read call が拒否される。sentinel は短い固定1行を直接 prompt する。
RUNTIME_ID3="rtcodexdirect1"
DIR3="$WORKROOT/runtime3"
mkdir -p "$DIR3"
PREP_CALLED="$WORKROOT/codex-prepare-called"
agentctl_backend_codex_prepare_operation_file() {
  : >"$PREP_CALLED"
  echo "$DIR3/should-not-be-used.txt"
}
agentctl_backend_codex_bootstrap_message() {
  printf 'BOOTSTRAP_WITHOUT_SENTINEL'
}
cat >"$WORKROOT/fake-codex-sentinel-backend.sh" <<SCRIPT
#!/bin/bash
IFS= read -r line
printf '%s\n' "\$line" >"$DIR3/seen-prompt.txt"
jq -n --arg runtime_id "$RUNTIME_ID3" '{runtime_id:\$runtime_id, decision:"deny"}' >"$DIR3/guard-sentinel.json"
sleep 60
SCRIPT
chmod +x "$WORKROOT/fake-codex-sentinel-backend.sh"
tmux new-session -d -s settlecodex -c "$WORKROOT" "$WORKROOT/fake-codex-sentinel-backend.sh"
PANE3=$(tmux display-message -p -t settlecodex '#{pane_id}')
if AGENTCTL_SENTINEL_SETTLE_TIMEOUT_SECONDS=5 agentctl_verify_guard_sentinel codex "$PANE3" "$DIR3" "$RUNTIME_ID3"; then
  if [ ! -e "$PREP_CALLED" ] && grep -qF "#agentctl-guard-sentinel:$RUNTIME_ID3" "$DIR3/seen-prompt.txt"; then
    pass "Codex guard sentinel is sent directly with the marker in the first prompt (no bootstrap-file deadlock)"
  else
    fail "Codex guard sentinel used an operation-file bootstrap or omitted the marker from the first prompt"
  fi
else
  fail "Codex direct sentinel prompt test unexpectedly failed"
fi
tmux kill-session -t settlecodex >/dev/null 2>&1 || true

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl guard sentinel settle-barrier unit tests passed."
else
  echo "Some agentctl guard sentinel settle-barrier unit tests FAILED."
fi
exit "$FAILED"
