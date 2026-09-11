#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
#
# guard startup verification を実 Codex backend で確認する live E2E。
# tests/integration/test_agentctl_guard_sentinel_e2e.sh は実 Claude backend
# しか検証しておらず、Codex は hooks.json 配線が global/deployed 経由である点が
# Claude (session-local settings) と根本的に異なるため、別途 real Codex の
# interactive TUI (agentctl start --backend codex が実際に起動する経路と同じ、
# `codex` コマンドを tmux で起動する経路) で機械的に証明する。app-server-only の
# `codex exec` はこの起動経路の証拠にならないため使わない。
#
# 追加で、guard-sentinel evidence 出現直後に初回 mission delivery が割り込む
# race (sentinel turn の画面描画がまだ終わっていない状態で mission の
# paste-buffer が送られ、2 つの turn が画面上で混ざる懸念) を検証する。
# agentctl_verify_guard_sentinel の settle barrier (agentctl-common.sh) は
# tests/unit/test_agentctl_guard_sentinel_settle.sh で fake pane を使い
# 決定的に検証済みのため、ここでは実 Codex を使って「mission delivery 後に
# 個別の steer 操作の結果が破損せず届く」ことまでを追加の生きた証拠とする。
#
# 実 Codex CLI に認証済み credential が必要なため、codex バイナリが無い/
# 疎通できない環境では gracefully skip する。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping guard sentinel Codex live E2E"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping guard sentinel Codex live E2E"; exit 0; }
command -v codex >/dev/null 2>&1 || { echo "⚠️  codex CLI not found; skipping guard sentinel Codex live E2E"; exit 0; }
timeout 45 codex exec "reply with exactly: ok" </dev/null >/tmp/agentctl-sentinel-codex-e2e-probe.out 2>&1
if ! grep -qi "ok" /tmp/agentctl-sentinel-codex-e2e-probe.out; then
  echo "⚠️  codex CLI not authenticated/reachable; skipping guard sentinel Codex live E2E"
  rm -f /tmp/agentctl-sentinel-codex-e2e-probe.out
  exit 0
fi
rm -f /tmp/agentctl-sentinel-codex-e2e-probe.out

# agentctl start --backend codex は $HOME/.codex/hooks.json / $HOME/bin/agentctl-*.sh
# の deployed 状態を preflight で検証する (agentctl-backend-codex.sh)。この live
# E2E が現行 worktree の変更を実際に証明するには、対象の deployed copy が
# worktree source と一致していなければならない (chezmoi apply 済みが前提)。
for pair in \
  "$HOME/bin/agentctl-policy-dispatcher.sh:$REPO_ROOT/home/bin/agentctl-policy-dispatcher.sh" \
  "$HOME/bin/agentctl-classify.sh:$REPO_ROOT/home/bin/agentctl-classify.sh" \
  "$HOME/bin/agentctl-common.sh:$REPO_ROOT/home/bin/agentctl-common.sh" \
  "$HOME/bin/agentctl-backend-codex.sh:$REPO_ROOT/home/bin/agentctl-backend-codex.sh" \
  "$HOME/.codex/hooks/agentctl-policy-dispatcher.sh:$REPO_ROOT/home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh"; do
  deployed="${pair%%:*}"
  source_file="${pair##*:}"
  if [ ! -f "$deployed" ] || ! diff -q "$deployed" "$source_file" >/dev/null 2>&1; then
    echo "⚠️  deployed $deployed is stale relative to worktree source; skipping guard sentinel Codex live E2E (run: chezmoi apply -S \"$REPO_ROOT/home\" --source-path <files>)"
    exit 0
  fi
done

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-sentinel-codex-e2e-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"

mkdir -p "$WORKROOT/worktree"

# Codex は初回起動する cwd ごとに "Do you trust the contents of this
# directory?" の確認 TUI を挟み、これはこのテスト固有の使い捨て mktemp ディレクトリ
# 相手には毎回必ず出る (guard sentinel 自体とは無関係な Codex 側の別機能)。
# 確認を Enter で進めると単に trust dialog の選択が進むだけで、送った sentinel
# text は shell command として一切実行されない。$HOME/.codex/config.toml の
# 既存 [projects] エントリと同じ形式で worktree を事前 trusted 化し、テスト
# 終了時に元の config.toml へ復元する。
CODEX_CONFIG="$HOME/.codex/config.toml"
CODEX_CONFIG_BACKUP="$WORKROOT/config.toml.orig"
if [ -f "$CODEX_CONFIG" ]; then
  cp -p "$CODEX_CONFIG" "$CODEX_CONFIG_BACKUP"
  printf '\n  [projects."%s"]\n    trust_level = "trusted"\n' "$WORKROOT/worktree" >>"$CODEX_CONFIG"
fi

cleanup_all() {
  tmux kill-server >/dev/null 2>&1 || true
  if [ -f "$CODEX_CONFIG_BACKUP" ]; then
    cp -p "$CODEX_CONFIG_BACKUP" "$CODEX_CONFIG"
  fi
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT
POLICY="$WORKROOT/policy.json"
cat >"$POLICY" <<JSON
{"version":1,"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false},"scope":{"repositories":[{"id":"primary","git_common_dir":"/nonexistent/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}],"remotes":[],"production_targets":[]}}
JSON

RID=$(timeout 150 bash "$AGENTCTL" start --name e2ecodex --cwd "$WORKROOT/worktree" --backend codex --policy-file "$POLICY" --mission-stdin <<<"Say hello and then stop, do nothing else." 2>"$WORKROOT/start-err")
START_RC=$?

if [ "$START_RC" -eq 0 ] && [ -n "$RID" ]; then
  pass "agentctl start (real Codex backend, real interactive TUI) publishes a runtime after passing guard sentinel verification"
else
  fail "agentctl start with real Codex backend failed: rc=$START_RC $(cat "$WORKROOT/start-err" 2>/dev/null)"
  echo
  echo "Some agentctl guard sentinel Codex live E2E tests FAILED."
  exit 1
fi

EVIDENCE="$WORKROOT/state/agentctl/runtimes/e2ecodex/guard-sentinel.json"
if [ -f "$EVIDENCE" ]; then
  EV_RID=$(jq -r '.runtime_id' "$EVIDENCE")
  EV_DECISION=$(jq -r '.decision' "$EVIDENCE")
  [ "$EV_RID" = "$RID" ] && [ "$EV_DECISION" = "deny" ] \
    && pass "real Codex PreToolUse hook fired for the sentinel probe and the dispatcher recorded a deny (mechanical proof, not just config grep)" \
    || fail "guard sentinel evidence present but does not match this generation (runtime_id=$EV_RID decision=$EV_DECISION expected runtime_id=$RID decision=deny)"
else
  fail "guard sentinel evidence file was never written; real Codex process did not demonstrably load the PreToolUse guard"
fi

RECONCILE=$(bash "$AGENTCTL" status --name e2ecodex --json 2>/dev/null | jq -r '.reconcile')
[ "$RECONCILE" = "running" ] && pass "runtime remains running (initial mission delivery proceeded normally after guard sentinel verification succeeded, no crash from a sentinel/mission race)" \
  || fail "expected reconcile=running after successful guard sentinel verification, got: $RECONCILE"

# race-window proof: settle barrier がなければ、sentinel turn の描画中に mission
# の paste-buffer が割り込んで画面が混ざり、以降の turn 分離が壊れ得る。ここでは
# 初回 mission 送達が終わった後に、一意な marker を含む別の steer 操作を送り、
# その結果がそれ単体の turn として正しく届く (=前の turn と混ざって欠落/破損
# しない) ことを確認する。
MARKER="codex-race-check-$$"
# prompt 自体に含まれる marker を grep すると shell 実行なしでも偽陽性になる。
# echo の出力を sha256sum した digest は prompt に存在しないため、その digest を
# pane で観測して通常の許可 shell command が実際に PreToolUse を通過したことを証明する。
MARKER_DIGEST=$(printf '%s\n' "$MARKER" | sha256sum | awk '{print $1}')
bash "$AGENTCTL" steer --name e2ecodex --runtime-id "$RID" --stdin \
  <<<"Run exactly this read-only command via the Bash tool and then stop: echo $MARKER | sha256sum" \
  >/dev/null

MARKER_SEEN=0
for _ in $(seq 1 60); do
  PANE_TEXT=$(bash "$AGENTCTL" logs --name e2ecodex --lines 400 2>/dev/null || true)
  if echo "$PANE_TEXT" | grep -qF "$MARKER_DIGEST"; then
    MARKER_SEEN=1
    break
  fi
  sleep 2
done
[ "$MARKER_SEEN" -eq 1 ] && pass "a distinct follow-up turn executes an ordinary allowed Bash command after guard sentinel verification" \
  || fail "did not observe the derived shell-output digest; the follow-up command may have been denied or not executed"

# `codex queue` が busy turn への steering ではなく本当に次 turn を作ったことを、
# persisted rollout の user bootstrap turn_id で機械的に証明する。session_id は
# sentinel が current runtime_id に bind した registry entry から取得し、同じ
# rollout 内の operation-file bootstrap 2 件 (initial mission / steer) が別 turn_id
# でなければ fail する。
SESSION_ID=""
SESSION_MATCHES=0
for binding in "$HOME/.local/state/agentctl/codex-hook-bindings/sessions"/*.json; do
  [ -f "$binding" ] || continue
  if jq -e --arg rid "$RID" '.runtime_id == $rid and .backend == "codex"' "$binding" >/dev/null 2>&1; then
    SESSION_ID=$(jq -r '.session_id // empty' "$binding")
    SESSION_MATCHES=$((SESSION_MATCHES + 1))
  fi
done

if [ "$SESSION_MATCHES" -eq 1 ] && [ -n "$SESSION_ID" ]; then
  ROLLOUT=$(find "$HOME/.codex/sessions" -type f -name "*-${SESSION_ID}.jsonl" -print 2>/dev/null | head -1)
else
  ROLLOUT=""
fi

if [ -n "$ROLLOUT" ] && [ -f "$ROLLOUT" ]; then
  mapfile -t BOOTSTRAP_TURNS < <(jq -r '
    select(.type == "response_item" and .payload.type == "message" and .payload.role == "user")
    | ((.payload.content // []) | map(.text // "") | join("")) as $text
    | select($text | contains("agentctl transport artifact:"))
    | .payload.internal_chat_message_metadata_passthrough.turn_id // empty
  ' "$ROLLOUT")
  TURN_COUNT=${#BOOTSTRAP_TURNS[@]}
  if [ "$TURN_COUNT" -ge 2 ]; then
    INITIAL_TURN=${BOOTSTRAP_TURNS[$((TURN_COUNT - 2))]}
    STEER_TURN=${BOOTSTRAP_TURNS[$((TURN_COUNT - 1))]}
    [ -n "$INITIAL_TURN" ] && [ -n "$STEER_TURN" ] && [ "$INITIAL_TURN" != "$STEER_TURN" ] \
      && pass "Codex queued steer is persisted as a separate turn_id from the initial mission ($INITIAL_TURN -> $STEER_TURN)" \
      || fail "Codex queued steer did not get a distinct turn_id (initial=$INITIAL_TURN steer=$STEER_TURN)"
  else
    fail "Codex rollout contains only $TURN_COUNT operation-file bootstrap turn(s); expected initial mission + queued steer"
  fi
else
  fail "could not resolve the persisted Codex rollout for runtime session_id=$SESSION_ID (matches=$SESSION_MATCHES)"
fi

bash "$AGENTCTL" stop --name e2ecodex --runtime-id "$RID" >/dev/null 2>&1 || true
bash "$AGENTCTL" cleanup --name e2ecodex --runtime-id "$RID" >/dev/null 2>&1 || true

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl guard sentinel Codex live E2E tests passed."
else
  echo "Some agentctl guard sentinel Codex live E2E tests FAILED."
fi
exit "$FAILED"
